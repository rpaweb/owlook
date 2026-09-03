# frozen_string_literal: true

# Shared test doubles and helpers for collector_ci_test.rb,
# collector_queue_test.rb, collector_deploy_test.rb, and
# collector_notifications_test.rb — extracted from what used to be one
# shared `private` section at the bottom of a single collector_test.rb.
# `module Owlook::CollectorTestSupport` (compact form) rather than nested
# `module Owlook; module CollectorTestSupport; end; end` blocks purely so
# every line below keeps the exact same indentation it already had as the
# body of that old class — `include`d into each Minitest::Test subclass
# above, which pulls in both the private helper methods (`private` here
# still applies through include) and the nested Fake*/Raising*/Slow*/
# Probing* classes (never affected by `private` — only method defs are) as
# bare constants via Ruby's normal ancestor-chain constant lookup.
module Owlook::CollectorTestSupport
  private

  def ci_branches(state_path)
    JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }.map { |e| e["branch"] }.sort
  end

  # writer's path is never touched — none of the tests that use this write
  # a snapshot (StateWriter only hits disk inside #write), so there's no
  # need for a real tmpdir here.
  def build_collector(**overrides)
    Owlook::Collector.new(
      config_loader: -> { Owlook::Config.new({ "projects" => [] }) },
      store: Owlook::Store.new,
      writer: Owlook::StateWriter.new("/tmp/owlook-test-unused-state.json"),
      github_source: FakeGithubSource.new({}), **overrides
    )
  end

  def with_project(remote:, branch:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "project")
      init_repo(path, remote: remote, branch: branch)
      yield path
    end
  end

  def init_repo(path, remote:, branch:)
    FileUtils.mkdir_p(path)
    Dir.chdir(path) do
      system("git", "init", "-q", "-b", branch)
      system("git", "config", "user.email", "test@example.com")
      system("git", "config", "user.name", "Test")
      File.write("README.md", "hi")
      system("git", "add", "README.md")
      system("git", "commit", "-q", "-m", "init")
      system("git", "remote", "add", "origin", remote) if remote
    end
  end

  # Routes latest_run(owner:, repo:, branch:) to canned results, keyed by
  # [owner, repo, branch]. Missing key means "no runs" (nil), matching the
  # real Sources::GitHub contract. branches_with_runs is routed separately,
  # keyed by [owner, repo], defaulting to [] (unstubbed = no recent runs).
  class FakeGithubSource
    # branch_routes is a plain trailing positional (not a keyword) so a
    # bare `["a", "b", "c"] => {...}` hash-rocket list at a call site still
    # collects into `routes` the old, brace-free way — a keyword parameter
    # here would make Ruby treat that trailing list as keyword arguments
    # instead once one is present, breaking every existing call site.
    def initialize(routes, branch_routes = {})
      @routes = routes
      @branch_routes = branch_routes
    end

    def latest_run(owner:, repo:, branch:)
      @routes[[owner, repo, branch]]
    end

    def branches_with_runs(owner:, repo:, limit: 100)
      @branch_routes.fetch([owner, repo], [])
    end
  end

  # Every branch reports success after a real sleep — proving branches
  # are actually polled concurrently (real wall-clock time, not just
  # interleaved) needs a fake that actually blocks, not an instant one.
  class SlowGithubSource
    def initialize(delay:, branches:)
      @delay = delay
      @branches = branches
    end

    def latest_run(owner:, repo:, branch:)
      sleep(@delay)
      return nil unless @branches.include?(branch)

      { head_sha: "sha-#{branch}", status: "completed", conclusion: "success",
        updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
    end
  end

  # Tracks how many #track blocks are in flight at once. Proves both
  # halves of a concurrency-cap claim at the same time: max stays at or
  # under the configured limit (the cap holds) and max is still above 1
  # (real concurrency is happening, not accidentally serialized down to
  # one-at-a-time by a bug in the cap itself).
  class ConcurrencyProbe
    def initialize
      @mutex = Mutex.new
      @current = 0
      @max = 0
    end

    def track
      @mutex.synchronize do
        @current += 1
        @max = @current if @current > @max
      end
      yield
    ensure
      @mutex.synchronize { @current -= 1 }
    end

    attr_reader :max
  end

  # Same shape as SlowGithubSource, but reports concurrency-in-flight to a
  # ConcurrencyProbe instead of just sleeping — needed to prove
  # work_concurrently's cap actually holds, not just that polling is
  # concurrent at all.
  class ProbingGithubSource
    def initialize(delay:, branches:, probe:)
      @delay = delay
      @branches = branches
      @probe = probe
    end

    def latest_run(owner:, repo:, branch:)
      @probe.track do
        sleep(@delay)
        next nil unless @branches.include?(branch)

        { head_sha: "sha-#{branch}", status: "completed", conclusion: "success",
          updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
      end
    end
  end

  class FakeKamalSource
    def initialize(routes)
      @routes = routes
    end

    def destinations(project_path)
      @routes.fetch(project_path, [])
    end
  end

  # Same idea as RaisingWorkflowsSource, for poll_project_queues' own
  # unguarded call to Sources::Kamal#destinations.
  class RaisingKamalSource
    def initialize(routes)
      @routes = routes
    end

    def destinations(project_path)
      route = @routes.fetch(project_path, [])
      raise route if route.is_a?(Exception)

      route
    end
  end

  # Records every call instead of actually shelling out to
  # omarchy-notification-send — a Ruby test suite must never pop a real
  # desktop notification.
  class FakeNotifier
    Notification = Struct.new(:headline, :description, :urgency, keyword_init: true)
    attr_reader :sent

    def initialize
      @sent = []
    end

    def notify(headline, description, urgency: "normal")
      @sent << Notification.new(headline: headline, description: description, urgency: urgency)
    end
  end

  # Routes branches(project_path) to canned lists. Missing key means "no
  # push-triggered workflow" ([]), matching the real Sources::Workflows
  # contract.
  class FakeWorkflowsSource
    def initialize(routes)
      @routes = routes
    end

    def branches(project_path)
      @routes.fetch(project_path, [])
    end
  end

  # A route mapped to an Exception instance raises it instead of returning
  # it — for proving one project's own poll blowing up outright (not a
  # single branch's, see poll_branches_concurrently's own isolation)
  # doesn't take the rest of the cycle down with it.
  class RaisingWorkflowsSource
    def initialize(routes)
      @routes = routes
    end

    def branches(project_path)
      route = @routes.fetch(project_path, [])
      raise route if route.is_a?(Exception)

      route
    end
  end

  FakeSettings = Struct.new(:all_branches, keyword_init: true) do
    def all_branches?
      !!all_branches
    end
  end

  # A real StateWriter only exposes what's on disk right now — this
  # records every snapshot passed to #write, in order, so a test can
  # assert on the sequence of writes (e.g. "checking" landed before the
  # real result), not just the final state.
  class RecordingWriter
    attr_reader :snapshots

    def initialize
      @snapshots = []
    end

    def write(snapshot)
      @snapshots << snapshot
      true
    end
  end

  # Routes status(destination:) to canned counts, keyed by [destination].
  # A destination with no stubbed route raises, matching the real
  # Sources::Queue contract for an unreachable/misconfigured destination.
  class FakeQueueSource
    def initialize(routes)
      @routes = routes
    end

    def status(project_path:, destination:)
      @routes.fetch([destination]) { raise Owlook::Sources::Queue::CommandFailedError.new(["kamal"], FakeStatus.new(1), "not stubbed") }
    end

    FakeStatus = Struct.new(:exitstatus)
  end

  class FakeDeploySource
    def initialize(routes)
      @routes = routes
    end

    def version(project_path:, destination:)
      @routes.fetch([destination]) { raise Owlook::Sources::Deploy::CommandFailedError.new(["kamal"], FakeStatus.new(1), "not stubbed") }
    end

    FakeStatus = Struct.new(:exitstatus)
  end

  # Every destination reports a clean queue after a real sleep — same
  # role as SlowGithubSource, proving destinations are actually polled
  # concurrently (real wall-clock time), not just correctly regardless of
  # order.
  class SlowQueueSource
    def initialize(delay:, destinations:)
      @delay = delay
      @destinations = destinations
    end

    def status(project_path:, destination:)
      sleep(@delay)
      raise Owlook::Sources::Queue::CommandFailedError.new(["kamal"], FakeQueueSource::FakeStatus.new(1), "not stubbed") \
        unless @destinations.include?(destination)

      { ready: 0, failed: 0 }
    end
  end

  # Same shape as SlowQueueSource, but reports concurrency-in-flight to a
  # ConcurrencyProbe — see ProbingGithubSource's own comment, same reason.
  class ProbingQueueSource
    def initialize(delay:, destinations:, probe:)
      @delay = delay
      @destinations = destinations
      @probe = probe
    end

    def status(project_path:, destination:)
      @probe.track do
        sleep(@delay)
        raise Owlook::Sources::Queue::CommandFailedError.new(["kamal"], FakeQueueSource::FakeStatus.new(1), "not stubbed") \
          unless @destinations.include?(destination)

        { ready: 0, failed: 0 }
      end
    end
  end
end
