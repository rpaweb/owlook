# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../support/collector_test_helpers"

# Split out of one 1600+-line collector_test.rb by concern, mirroring the
# same seams Collector's own source already has (poll_ci_once/poll_queues_once/
# deploy freshness/notifications) — not a new organizing idea, the same one
# large Ruby test suites (Rails' own AR tests, for one) already use: several
# files, each still testing the same class, split by topic rather than one
# file per class no matter how large it gets. Shared fakes/helpers live in
# collector_test_helpers.rb (test/support/), included below rather than
# redefined per file.
# poll_ci_once — recording, placeholders, branch selection (push-workflow and
# "all branches" broad mode), pruning, concurrency, and per-project failure
# isolation. Notification behavior for a CI transition lives in
# collector_notifications_test.rb instead — see that file's own header.
class Owlook::CollectorCiTest < Minitest::Test
  include Owlook::CollectorTestSupport

  # write_snapshot (used throughout poll_ci_once/poll_queues_once) never
  # runs at all when there are zero configured projects — poll_project_ci/
  # poll_project_queues, its only callers, never get invoked for an empty
  # project list. Without an explicit, unconditional write, the state file
  # never gets created at all in that case, which the widget can't tell
  # apart from "the collector hasn't run its first cycle yet" — see
  # flush_state, the fix, called once by bin/owlook-collector at the end
  # of every cycle regardless of what ran.
  def test_flush_state_writes_an_empty_array_when_there_are_no_projects
    Dir.mktmpdir do |state_dir|
      state_path = File.join(state_dir, "state.json")
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [] }) },
        store: Owlook::Store.new,
        writer: Owlook::StateWriter.new(state_path),
        github_source: FakeGithubSource.new({})
      )

      collector.poll_ci_once
      collector.poll_queues_once
      collector.flush_state

      assert_equal [], JSON.parse(File.read(state_path))
    end
  end

  def test_poll_ci_once_records_an_observation_per_project_and_writes_the_state_file
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new({
                                               %w[acme widgets main] => {
                                                 head_sha: "abc123", status: "completed", conclusion: "success",
                                                 updated_at: "2026-08-26T12:00:00Z", actor: "rafael",
                                                 name: "07. Checks",
                                                 jobs: [
                                                   { name: "test", status: "completed", conclusion: "success",
                                                     steps: [] },
                                                   { name: "lint", status: "completed", conclusion: "success",
                                                     steps: [] },
                                                   { name: "deploy", status: "completed", conclusion: "skipped",
                                                     steps: [] }
                                                 ]
                                               }
                                             })
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once

        on_disk = JSON.parse(File.read(state_path))
        ci_rows = on_disk.select { |e| e["kind"] == "ci" }

        assert_equal 1, ci_rows.size
        entry = ci_rows.first

        assert_equal "acme/widgets", entry["project"]
        assert_equal "ci", entry["kind"]
        assert_equal "main", entry["branch"]
        assert_nil entry["destination"]
        assert_equal "abc123", entry["version"]
        assert_equal "success", entry["state"]
        assert_equal "rafael", entry["author"]
        assert_equal "github", entry["source"]
        # skipped jobs don't count against the total the way a failure
        # would — GitHub's own UI treats a run with only skips as green too.
        assert_equal({ "jobs_total" => 3, "jobs_passed" => 2, "jobs_skipped" => 1, "workflow_name" => "07. Checks" },
                     entry["details"])

        # A project-level "ci_timing" row rides along too — how long this
        # cycle actually took (see Collector#record_timing).
        timing = on_disk.find { |e| e["kind"] == "ci_timing" }

        assert timing, "expected a ci_timing row"
        assert_kind_of Numeric, timing["details"]["duration_seconds"]
      end
    end
  end

  # A branch the store has never seen gets an immediate "checking" row,
  # written before the real GitHub calls even start — same reason
  # poll_queues_once announces a destination before its real check. GitHub
  # Actions is fast, but a project's tab shouldn't say "no CI runs found"
  # for however briefly it takes to find out otherwise.
  def test_poll_ci_once_writes_a_checking_placeholder_before_the_real_check_completes
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      writer = RecordingWriter.new
      github_source = FakeGithubSource.new(
        %w[acme widgets main] => { head_sha: "abc123", status: "completed", conclusion: "success",
                                   updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
      )
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: github_source
      )

      collector.poll_ci_once

      checking_writes = writer.snapshots.select { |snap| snap.any? { |row| row[:state] == "checking" } }

      assert_equal 1, checking_writes.size, "expected exactly one write with a checking placeholder"

      final = writer.snapshots.last

      assert_equal "success", final.find { |row| row[:branch] == "main" }[:state]
    end
  end

  def test_poll_ci_once_does_not_reannounce_an_already_known_branch
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      writer = RecordingWriter.new
      github_source = FakeGithubSource.new(
        %w[acme widgets main] => { head_sha: "abc123", status: "completed", conclusion: "success",
                                   updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
      )
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: github_source
      )

      collector.poll_ci_once
      collector.poll_ci_once

      checking_writes = writer.snapshots.select { |snap| snap.any? { |row| row[:state] == "checking" } }

      assert_equal 1, checking_writes.size, "a known branch should never be reset to checking"
    end
  end

  # Regression: the checking placeholder used to stamp `timestamp: Time.now`.
  # A real run's timestamp is GitHub's own updated_at — the underlying
  # event's time, not "when the collector saw it" — which is very often
  # older than "right now" (nobody's pushed to this branch in days). Store
  # only keeps whichever observation has the newer timestamp, so a
  # placeholder stamped "now" would outrank a real-but-old run and never
  # get replaced.
  def test_poll_ci_once_replaces_the_checking_placeholder_even_when_the_real_run_is_old
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          %w[acme widgets main] => { head_sha: "abc123", status: "completed", conclusion: "success",
                                     updated_at: "2020-01-01T00:00:00Z", actor: "rafael" } # years old, well before "now"
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once

        on_disk = JSON.parse(File.read(state_path))
        entry = on_disk.find { |row| row["branch"] == "main" }

        assert_equal "success", entry["state"]
        assert_equal "abc123", entry["version"]
      end
    end
  end

  # A project with no Actions runs yet still gets a row — not a silent
  # skip. Otherwise it has no CI row and (usually) no queue row either, so
  # it's invisible to the widget: no tab, no "0 tracked", nothing to
  # distinguish "nothing has run yet" from "never configured at all".
  def test_poll_ci_once_records_a_no_runs_row_when_a_project_has_no_workflow_runs
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}) # no runs for any project
        )

        collector.poll_ci_once

        on_disk = JSON.parse(File.read(state_path))
        entry = on_disk.find { |e| e["kind"] == "ci" }

        assert_equal "acme/widgets", entry["project"]
        assert_equal "ci", entry["kind"]
        assert_equal "main", entry["branch"]
        assert_equal "no_runs", entry["state"]
        assert_nil entry["version"]
        assert_nil entry["author"]
        assert_equal({}, entry["details"])
      end
    end
  end

  def test_poll_ci_once_skips_a_project_with_no_github_remote_and_continues
    Dir.mktmpdir do |dir|
      no_remote_project = File.join(dir, "no-remote")
      init_repo(no_remote_project, remote: nil, branch: "main")

      with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |good_project|
        state_path = File.join(dir, "state.json")
        github_source = FakeGithubSource.new(
          %w[acme widgets main] => {
            head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael"
          }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [no_remote_project, good_project] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once

        on_disk = JSON.parse(File.read(state_path))
        ci_rows = on_disk.select { |e| e["kind"] == "ci" }

        assert_equal 1, ci_rows.size
        assert_equal "acme/widgets", ci_rows.first["project"]
      end
    end
  end

  # A project whose workflows are wired to more than one branch (master ->
  # production, staging -> staging) gets a CI row for each — the branch
  # checked out locally is no longer the only thing that decides what's
  # polled.
  def test_poll_ci_once_polls_every_branch_a_workflow_pushes_to
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          %w[acme widgets master] => { head_sha: "aaa111", status: "completed", conclusion: "success",
                                       updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
          %w[acme widgets staging] => { head_sha: "bbb222", status: "completed", conclusion: "failure",
                                        updated_at: "2026-08-26T12:05:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => %w[master staging])
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }.sort_by { |e| e["branch"] }

        assert_equal 2, ci_rows.size
        assert_equal(%w[master staging], ci_rows.map { |e| e["branch"] })
        assert_equal "success", ci_rows.find { |e| e["branch"] == "master" }["state"]
        assert_equal "failure", ci_rows.find { |e| e["branch"] == "staging" }["state"]
      end
    end
  end

  # The real bug this covers: a broad-mode poll of N branches previously
  # took N round-trips, back to back. Branches are polled concurrently now,
  # so 5 branches at ~40ms each finishes in about one branch's time, not
  # the sum of all five.
  def test_poll_ci_once_polls_branches_concurrently_not_one_at_a_time
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        branches = %w[a b c d e]
        github_source = SlowGithubSource.new(delay: 0.04, branches: branches)
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => branches)
        )

        started = Time.now
        collector.poll_ci_once
        elapsed = Time.now - started

        # Sequential would be >= 5 * 0.04 = 0.2s; concurrent should land
        # close to a single branch's delay. 0.12s leaves real headroom for
        # thread scheduling/CI-machine jitter without being able to pass
        # if this silently regressed back to sequential.
        assert_operator elapsed, :<, 0.12,
                        "expected concurrent branch polling, took #{elapsed.round(3)}s for 5 branches at 0.04s each"

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }

        assert_equal branches.sort, ci_rows.map { |e| e["branch"] }.sort
      end
    end
  end

  # The real motivation for MAX_CONCURRENT_REQUESTS: a repo with hundreds
  # of branches (a broad-mode poll of something the size of rails/rails,
  # say) shouldn't fire one request per branch all at once — that risks
  # tripping GitHub's secondary/abuse rate limiting, a different
  # mechanism than the 5000/hour primary limit. max_concurrent_requests
  # is injected small here so the cap is observable without needing
  # anywhere near that many real branches/threads in a test.
  def test_poll_ci_once_caps_concurrent_branch_polling
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      branches = (1..10).map { |i| "branch-#{i}" }
      probe = ConcurrencyProbe.new
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
        store: Owlook::Store.new,
        writer: Owlook::StateWriter.new("/tmp/owlook-test-unused-state.json"),
        github_source: ProbingGithubSource.new(delay: 0.02, branches: branches, probe: probe),
        workflows_source: FakeWorkflowsSource.new(project_path => branches),
        max_concurrent_requests: 3
      )

      collector.poll_ci_once

      assert_operator probe.max, :<=, 3, "expected at most 3 branches in flight at once"
      assert_operator probe.max, :>, 1, "expected real concurrency, not accidentally serialized"
    end
  end

  # A project with no push-triggered workflow (PR-only CI, or none at all)
  # falls back to whatever's checked out locally instead of tracking
  # nothing — same single-branch behavior as before Sources::Workflows
  # existed.
  def test_poll_ci_once_falls_back_to_the_checked_out_branch_without_a_push_workflow
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          %w[acme widgets main] => { head_sha: "abc123", status: "completed", conclusion: "success",
                                     updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new({})
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }

        assert_equal 1, ci_rows.size
        assert_equal "main", ci_rows.first["branch"]
      end
    end
  end

  # With the widget's "all branches" setting on, every branch with a
  # recent run is polled — dependabot included — instead of only the ones
  # a push-triggered workflow names.
  def test_poll_ci_once_polls_every_branch_with_a_run_when_all_branches_setting_is_on
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          {
            %w[acme widgets master] => { head_sha: "aaa111", status: "completed", conclusion: "success",
                                         updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
            ["acme", "widgets", "dependabot/bundler/rails-8.1"] => { head_sha: "ccc333", status: "completed",
                                                                     conclusion: "success", updated_at: "2026-08-26T12:10:00Z", actor: "dependabot[bot]" }
          },
          { %w[acme widgets] => ["master", "dependabot/bundler/rails-8.1"] }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => %w[master staging]),
          settings_loader: -> { FakeSettings.new(all_branches: true) }
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }.sort_by { |e| e["branch"] }

        assert_equal(["dependabot/bundler/rails-8.1", "master"], ci_rows.map { |e| e["branch"] })
      end
    end
  end

  # The setting being on doesn't help when GitHub has no run history at
  # all yet — falls back the same way the default mode does.
  def test_poll_ci_once_falls_back_when_all_branches_setting_is_on_but_nothing_has_ever_run
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          %w[acme widgets staging] => { head_sha: "bbb222", status: "completed", conclusion: "success",
                                        updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => ["staging"]),
          settings_loader: -> { FakeSettings.new(all_branches: true) }
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }

        assert_equal 1, ci_rows.size
        assert_equal "staging", ci_rows.first["branch"]
      end
    end
  end

  # Flipping the toggle back off must not leave a dependabot branch it
  # discovered sitting in the state file forever — nothing else ever
  # prunes a Store entry, so Collector has to forget and re-announce.
  def test_poll_ci_once_forgets_branches_no_longer_relevant_when_all_branches_setting_changes
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          {
            %w[acme widgets master] => { head_sha: "aaa111", status: "completed", conclusion: "success",
                                         updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
            ["acme", "widgets", "dependabot/bundler/rails-8.1"] => { head_sha: "ccc333", status: "completed",
                                                                     conclusion: "success", updated_at: "2026-08-26T12:10:00Z", actor: "dependabot[bot]" }
          },
          { %w[acme widgets] => ["master", "dependabot/bundler/rails-8.1"] }
        )
        all_branches = false
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => ["master"]),
          settings_loader: -> { FakeSettings.new(all_branches: all_branches) }
        )

        collector.poll_ci_once

        assert_equal ["master"], ci_branches(state_path)

        all_branches = true
        collector.poll_ci_once

        assert_equal ["dependabot/bundler/rails-8.1", "master"], ci_branches(state_path)

        all_branches = false
        collector.poll_ci_once

        assert_equal ["master"], ci_branches(state_path),
                     "the dependabot branch should be forgotten, not left over from all-branches mode"
      end
    end
  end

  # The test above reuses one Collector (and one in-memory Store) across
  # all three polls — which is how bin/owlook-collector *used* to run, but
  # not how it actually runs today (see BarWidget.qml's Timer+Process): a
  # fresh process, a fresh Collector, and Store.load(state_path)
  # rehydrating from disk, every single cycle. This reproduces that real
  # shape specifically, since an earlier version of this same pruning
  # logic (a Collector-level @known_all_branches transition check) passed
  # the test above while being silently dead in exactly this scenario —
  # every fresh process's first poll looked identical to a genuine
  # settings change, so the guard meant to protect a real first-ever poll
  # ended up suppressing every single cycle's prune instead.
  def test_poll_ci_once_forgets_stale_branches_across_separate_collector_processes
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          {
            %w[acme widgets master] => { head_sha: "aaa111", status: "completed", conclusion: "success",
                                         updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
            ["acme", "widgets", "dependabot/bundler/rails-8.1"] => { head_sha: "ccc333", status: "completed",
                                                                     conclusion: "success", updated_at: "2026-08-26T12:10:00Z", actor: "dependabot[bot]" }
          },
          { %w[acme widgets] => ["master", "dependabot/bundler/rails-8.1"] }
        )
        one_cycle = lambda { |all_branches|
          Owlook::Collector.new(
            config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
            store: Owlook::Store.load(state_path),
            writer: Owlook::StateWriter.new(state_path),
            github_source: github_source,
            workflows_source: FakeWorkflowsSource.new(project_path => ["master"]),
            settings_loader: -> { FakeSettings.new(all_branches: all_branches) }
          ).poll_ci_once
        }

        one_cycle.call(false)

        assert_equal ["master"], ci_branches(state_path)

        one_cycle.call(true)

        assert_equal ["dependabot/bundler/rails-8.1", "master"], ci_branches(state_path)

        one_cycle.call(false)

        assert_equal ["master"], ci_branches(state_path),
                     "a fresh process per cycle must still forget the dependabot branch, " \
                     "not just one that happens to keep the same Collector/Store around"
      end
    end
  end

  # Same class of bug as the branch-pruning tests above, one level up: a
  # project removed from config.yml stops being polled, but nothing else
  # ever removed what the Store already had for it — confirmed live (a
  # real project deleted from config.yml kept showing its last-known tab
  # indefinitely) before this existed.
  def test_poll_ci_once_forgets_a_project_dropped_from_config_across_separate_collector_processes
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_a|
      with_project(remote: "https://github.com/acme/gadgets.git", branch: "main") do |project_b|
        Dir.mktmpdir do |state_dir|
          state_path = File.join(state_dir, "state.json")
          github_source = FakeGithubSource.new(
            %w[acme widgets main] => { head_sha: "aaa111", status: "completed", conclusion: "success",
                                       updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
            %w[acme gadgets main] => { head_sha: "bbb222", status: "completed", conclusion: "success",
                                       updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
          )
          one_cycle = lambda { |project_paths|
            Owlook::Collector.new(
              config_loader: -> { Owlook::Config.new({ "projects" => project_paths }) },
              store: Owlook::Store.load(state_path),
              writer: Owlook::StateWriter.new(state_path),
              github_source: github_source
            ).poll_ci_once
          }

          one_cycle.call([project_a, project_b])

          projects = JSON.parse(File.read(state_path)).map { |e| e["project"] }.uniq.sort

          assert_equal ["acme/gadgets", "acme/widgets"], projects

          one_cycle.call([project_b])

          projects = JSON.parse(File.read(state_path)).map { |e| e["project"] }.uniq.sort

          assert_equal ["acme/gadgets"], projects,
                       "acme/widgets was removed from config.yml and should disappear entirely, " \
                       "not just stop being polled"
        end
      end
    end
  end

  # branches_to_poll (and everything else in poll_project_ci outside the
  # already-isolated per-branch loop, see poll_branches_concurrently) runs
  # unguarded except for GitRepo::NoGithubRemoteError — a real GitHub 502
  # raised from there took down the whole process mid-cycle, confirmed
  # live, silently skipping every project after the one that hit it. This
  # is the same "one item's failure doesn't cost the others" isolation
  # poll_branches_concurrently already gives individual branches, one
  # level up for whichever project's own poll blows up outright.
  def test_poll_ci_once_skips_a_project_whose_own_poll_raises_but_still_polls_the_rest
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_a|
      with_project(remote: "https://github.com/acme/gadgets.git", branch: "main") do |project_b|
        Dir.mktmpdir do |state_dir|
          state_path = File.join(state_dir, "state.json")
          github_source = FakeGithubSource.new(
            %w[acme gadgets main] => { head_sha: "bbb222", status: "completed", conclusion: "success",
                                       updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
          )
          workflows_source = RaisingWorkflowsSource.new(
            project_a => RuntimeError.new("GitHub API request failed: 502"),
            project_b => ["main"]
          )
          collector = Owlook::Collector.new(
            config_loader: -> { Owlook::Config.new({ "projects" => [project_a, project_b] }) },
            store: Owlook::Store.new,
            writer: Owlook::StateWriter.new(state_path),
            github_source: github_source,
            workflows_source: workflows_source
          )

          collector.poll_ci_once

          ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }

          assert_equal ["acme/gadgets"], ci_rows.map { |e| e["project"] }.uniq,
                       "acme/widgets' own poll blowing up shouldn't have stopped acme/gadgets from being polled"
        end
      end
    end
  end

  # config.yml is read once per poll, not once at construction — so adding a
  # project to it takes effect on the next cycle (well within 30s), not only
  # after a systemctl restart. No file-watching needed: the collector is
  # already looping this often anyway.
  def test_poll_ci_once_picks_up_config_changes_without_being_reconstructed
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          %w[acme widgets main] => {
            head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael"
          }
        )
        projects = []
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => projects }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once

        refute_path_exists state_path, "nothing configured yet, nothing to write"

        projects << project_path
        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }

        assert_equal 1, ci_rows.size
        assert_equal "acme/widgets", ci_rows.first["project"]
      end
    end
  end
end
