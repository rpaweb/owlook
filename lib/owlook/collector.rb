# frozen_string_literal: true

require "time"

module Owlook
  # Wires config -> git/kamal -> sources -> store -> state file. #run is the
  # infinite loop the systemd unit calls; all the actual logic lives in
  # #poll_ci_once / #poll_queues_once so it can be tested without looping or
  # sleeping.
  #
  # Two cadences, not one: GitHub Actions is a free API call, safe every 30s.
  # A queue or deploy check is a real SSH round-trip (kamal app exec /
  # kamal app version), so both run on their own, slower interval — #run
  # takes both separately.
  #
  # GitHub Actions produces "ci" observations, identified by project +
  # branch (see Observation#key). Queue and deploy checks both produce
  # observations identified by project + destination — a queue backlog or
  # a running version belongs to a deployed environment, not a branch —
  # so both need Sources::Kamal to know which destinations exist. A
  # deploy observation's own freshness (is it caught up with a branch CI
  # already verified?) is computed locally via git, not reported by
  # Kamal itself — see DeployFreshness.
  class Collector
    # A broad-mode ("all branches") poll's branch count comes straight from
    # GitHub — nothing here controls it. A repo with hundreds of open
    # branches (dependabot/renovate churn, or just a project the size of
    # rails/rails) would otherwise fire one request per branch, all at
    # once, no cap — comfortably fine for the tens of branches this was
    # built against, but a burst that size risks tripping GitHub's
    # secondary/abuse rate limiting, a different mechanism than the
    # 5000/hour primary limit (see #rate_limit). See work_concurrently.
    MAX_CONCURRENT_REQUESTS = 20

    # config_loader is a callable (e.g. -> { Owlook::Config.load(path) }),
    # not a static Config — called fresh on every poll rather than once at
    # construction, so editing config.yml takes effect on the next cycle
    # (well within 30s) instead of needing a systemd restart.
    # sleeper is injectable (real default: Kernel#sleep) purely so
    # #wait_for_next_poll is testable without an actual test waiting out a
    # real interval — see its own comment. max_concurrent_requests is
    # injectable so a test can prove the cap holds without needing
    # hundreds of real branches/threads to observe it.
    def initialize(config_loader:, store:, writer:, github_source:,
                   kamal_source: Sources::Kamal.new, queue_source: Sources::Queue.new,
                   deploy_source: Sources::Deploy.new,
                   workflows_source: Sources::Workflows.new,
                   settings_loader: -> { WidgetSettings.load },
                   notifier: Notifier.new,
                   max_concurrent_requests: MAX_CONCURRENT_REQUESTS,
                   sleeper: ->(seconds) { sleep(seconds) }, logger: nil)
      @config_loader = config_loader
      @store = store
      @writer = writer
      @github_source = github_source
      @kamal_source = kamal_source
      @queue_source = queue_source
      @deploy_source = deploy_source
      @workflows_source = workflows_source
      @settings_loader = settings_loader
      @notifier = notifier
      @max_concurrent_requests = max_concurrent_requests
      @sleeper = sleeper
      @logger = logger
      @known_all_branches = nil
      @known_projects = nil
      # Branches now poll concurrently (see poll_branches_concurrently) —
      # @store's own Hash isn't safe for unsynchronized concurrent
      # mutation, even across different keys.
      @store_mutex = Mutex.new
    end

    def poll_ci_once
      sync_all_branches_setting
      # Read once, remember it — the same value wait_for_next_poll compares
      # against on every tick, so an edit to config.yml made *during* a
      # blocking poll (not just between polls) is still caught, the same
      # class of race sync_all_branches_setting's own comment covers.
      current_projects = projects
      @known_projects = current_projects
      current_projects.each { |path| poll_project_ci(path) }
    end

    # Logs how long a full cycle actually takes — the queue interval is an
    # SSH round-trip per destination, real network time, not a free API
    # call like the CI interval; OWLOOK_QUEUE_POLL_INTERVAL's default was
    # picked as an estimate, never measured against a real server. This is
    # what makes that measurable: run it live and read the journal.
    def poll_queues_once
      started = Time.now
      projects.each { |path| poll_project_queues(path) }
      log("queue poll cycle finished in #{(Time.now - started).round(1)}s")
    end

    def run(ci_interval:, queue_interval:)
      next_queue_check = Time.now
      loop do
        next_queue_check = run_one_cycle(queue_interval: queue_interval, next_queue_check: next_queue_check)
        wait_for_next_poll(ci_interval)
      end
    end

    private

    # One iteration of #run's loop, pulled out so a test can call it
    # directly instead of looping/sleeping forever — same reason
    # poll_ci_once/poll_queues_once already are their own methods.
    # Returns the next_queue_check a caller should carry into the
    # following cycle.
    #
    # A project added to config.yml gets its CI checked promptly already
    # (poll_ci_once tracks @known_projects — see wait_for_next_poll).
    # Queues didn't share that: a project added right after a queue cycle
    # finished could sit for up to a full queue_interval before its
    # destinations got their first check — confirmed live, a newly-added
    # project's QUEUES section stayed on "checking" far longer than its
    # CI section did. Forcing an immediate check here closes that gap the
    # same way.
    def run_one_cycle(queue_interval:, next_queue_check:)
      previously_known_projects = @known_projects
      poll_ci_once
      next_queue_check = Time.now if @known_projects != previously_known_projects
      if Time.now >= next_queue_check
        poll_queues_once
        next_queue_check = Time.now + queue_interval
      end
      next_queue_check
    end

    # Sleeps in short ticks instead of one flat call for the whole
    # interval, so flipping the widget's "all branches" toggle (written to
    # shell.json — see WidgetSettings) takes effect within about a second
    # instead of waiting out the rest of a 30s interval. A config.yml edit
    # is made ahead of time with nobody watching, so a slow reload there
    # is fine; a toggle is clicked with the panel open, and nothing
    # visibly happening for up to 30s reads as broken.
    #
    # Compares against @known_all_branches (set by sync_all_branches_setting,
    # the last value this collector actually acted on) rather than a
    # baseline captured fresh here — a real bug this fixed: the queue poll
    # and a broad-mode CI poll both block for 20+ real seconds outside this
    # loop, so a toggle clicked during either window would already be
    # reflected in shell.json by the time this method's own baseline read
    # happened, making it look unchanged for the rest of that wait and
    # missing the fast path entirely (confirmed live: 27s+ of missed
    # detection window per cycle between the two).
    def wait_for_next_poll(ci_interval, tick: 1)
      elapsed = 0
      while elapsed < ci_interval
        step = [tick, ci_interval - elapsed].min
        @sleeper.call(step)
        elapsed += step
        if @settings_loader.call.all_branches? != @known_all_branches
          log("all_branches change detected after #{elapsed}s wait, polling early")
          return
        end
        # A project added (or removed) from config.yml gets the same
        # early wake as a settings toggle — the new project's tab and its
        # "checking" spinner (see announce_new_ci_branches) shouldn't sit
        # behind up to ci_interval of nothing visibly happening. The
        # regular CI/queue *data* refresh cadence is untouched by this —
        # only noticing that the tracked project list itself changed
        # jumps the queue.
        if projects != @known_projects
          log("project list changed after #{elapsed}s wait, polling early")
          return
        end
      end
    end

    # When the widget's "all branches" toggle flips, every CI row across
    # every project gets forgotten so the next poll re-announces from
    # scratch under the new mode — the same "checking" -> spinner ->
    # real-data sequence a first-ever poll goes through, because the
    # visible branch set has genuinely changed underneath it, not just
    # grown or shrunk unnoticed. Without this, switching "all branches"
    # back off would leave every dependabot/renovate branch it discovered
    # sitting in the state file forever — nothing else ever prunes a
    # Store entry. @known_all_branches starts as nil (neither true nor
    # false), so the very first call always "changes" too — harmless,
    # since there's nothing in the Store yet to forget.
    def sync_all_branches_setting
      current = @settings_loader.call.all_branches?
      return if current == @known_all_branches

      unless @known_all_branches.nil?
        log("all_branches setting changed #{@known_all_branches} -> #{current}, forgetting ci store")
        @store.forget_kind("ci")
      end
      @known_all_branches = current
    end

    # A config edit caught mid-write (or briefly invalid YAML) shouldn't
    # crash the loop — skip this one cycle's projects and try again next
    # time; the file is almost always valid by then.
    def projects
      @config_loader.call.projects
    rescue Config::MissingFileError, Config::InvalidFileError => e
      log("config reload failed, skipping this cycle: #{e.message}")
      []
    end

    def poll_project_ci(path)
      repo = GitRepo.new(path)
      owner, name = repo.owner_and_repo
      project = "#{owner}/#{name}"
      started = Time.now

      branches = branches_to_poll(path, repo, owner, name)
      # A branch the store has never seen gets an immediate "checking"
      # row, the same reason poll_project_queues announces a destination
      # before its real check — GitHub Actions is fast, but "fast" still
      # isn't instant, and the gap between the tab existing and its CI
      # data landing would otherwise render as "no CI runs found", which
      # isn't true yet. Written before the real per-branch GitHub calls.
      announce_new_ci_branches(project, branches)
      write_snapshot

      poll_branches_concurrently(owner, name, project, branches)
      # How long this project's CI actually took to resolve, start to
      # finish — the widget shows this next to "CI — N tracked" once the
      # section's own spinner clears, not before.
      record_timing(project, "ci_timing", "github", Time.now - started)
      write_snapshot
    rescue GitRepo::NoGithubRemoteError => e
      log("skipping #{path}: #{e.message}")
    end

    # GitHub Actions requests are I/O-bound — Ruby releases the GIL during
    # the actual network wait, so real threads here mean real concurrency,
    # not just interleaving. This is what turned a broad-mode poll of ~20
    # branches from ~25s (sequential, one HTTP round-trip at a time) into
    # something bounded by the slowest single branch instead of their sum
    # — and, just as importantly, stopped a settings-toggle click from
    # being stuck behind that whole sequential run before the collector
    # could even notice it (see wait_for_next_poll's own comment for that
    # half of the same underlying bug, confirmed live: a 28s detection gap
    # traced straight back to this).
    #
    # Capped at MAX_CONCURRENT_REQUESTS (see work_concurrently) — a broad
    # mode poll of a very large repo no longer bursts one request per
    # branch regardless of how many there are.
    #
    # Each item's own error is caught and logged rather than left to
    # crash the whole cycle — a burst of concurrent requests is more
    # likely to hit at least one transient failure than the same requests
    # spread out sequentially over 25 real seconds, so this isolation
    # matters more here than it did before.
    def poll_branches_concurrently(owner, name, project, branches)
      work_concurrently(branches) do |branch|
        poll_branch_ci(owner, name, project, branch)
      rescue StandardError => e
        log("#{project}@#{branch}: poll failed, skipping this cycle (#{e.class}: #{e.message})")
      end
    end

    def announce_new_ci_branches(project, branches)
      branches.each do |branch|
        pending = pending_ci_observation(project, branch)
        # Same rule as queues: only for a branch the store has no data
        # for at all. A known branch keeps whatever it last reported
        # until the real check replaces it — re-announcing it as
        # "checking" every cycle would flash real results back to
        # loading every 30s.
        next if @store.known?(pending.key)

        @store.record(pending)
      end
    end

    def pending_ci_observation(project, branch)
      Observation.new(
        project: project,
        kind: "ci",
        branch: branch,
        destination: nil,
        version: nil,
        state: "checking",
        details: {},
        # Epoch, not Time.now: a real CI observation's timestamp is the
        # GitHub run's own updated_at (when the underlying event actually
        # happened), which can easily be older than "right now" — a
        # branch nobody's pushed to in days still has a real, old
        # updated_at. Store#record keeps whichever timestamp is newer, so
        # a placeholder stamped "now" would sometimes outrank real data
        # and never get replaced. A placeholder should always lose,
        # unconditionally, to whatever real observation eventually shows
        # up — the oldest possible timestamp guarantees that.
        timestamp: Time.at(0),
        author: nil,
        source: "github",
        observed_at: Time.now
      )
    end

    # Two modes, chosen by the widget's own settings toggle (gear icon in
    # the panel — see WidgetSettings#all_branches? and Panel.qml). Off
    # (default): branches wired to a push-triggered workflow (master,
    # staging, …) — read locally from .github/workflows/*.yml, the same
    # reason Sources::Kamal reads config/deploy*.yml locally instead of
    # asking an API: it's free, and a workflow that runs
    # `on: push: branches: [...]` is the actual source of truth for "CI is
    # wired to this branch", unlike run history (which also surfaces every
    # dependabot/renovate branch that merely triggered a `pull_request`-only
    # workflow — confirmed noisy against a real repo). On: every branch
    # with a recent run, dependabot included — a GitHub API call, since
    # that's not something the local checkout can answer. Either mode falls
    # back to whatever's checked out locally when it finds nothing, so a
    # project isn't silently left untracked.
    def branches_to_poll(path, repo, owner, name)
      if @settings_loader.call.all_branches?
        broad = @github_source.branches_with_runs(owner: owner, repo: name)
        return broad if broad.any?
      end

      branches = @workflows_source.branches(path)
      branches.any? ? branches : [repo.current_branch]
    end

    def poll_branch_ci(owner, name, project, branch)
      run = @github_source.latest_run(owner: owner, repo: name, branch: branch)
      unless run
        log("#{project}@#{branch}: no workflow runs")
        # A row like any other, not a silent skip — otherwise a project
        # with no Actions runs yet has no CI row and no queue row, so it's
        # invisible to the widget: no tab, no "0 tracked", nothing to
        # distinguish it from a project nobody configured at all.
        return record_ci_observation(project, branch, state: "no_runs", version: nil,
                                                      details: {}, timestamp: Time.now, author: nil)
      end

      log("#{project}@#{branch}: #{run[:conclusion] || run[:status]}")
      record_ci_observation(project, branch, state: run[:conclusion] || run[:status],
                                             version: run[:head_sha],
                                             details: job_counts(run[:jobs]).merge(workflow_name: run[:name]),
                                             timestamp: Time.parse(run[:updated_at]), author: run[:actor])
    end

    def record_ci_observation(project, branch, state:, version:, details:, timestamp:, author:)
      record_and_notify(Observation.new(
                          project: project,
                          kind: "ci",
                          branch: branch,
                          destination: nil,
                          version: version,
                          state: state,
                          details: details,
                          timestamp: timestamp,
                          author: author,
                          source: "github",
                          observed_at: Time.now
                        ))
    end

    # "ci_timing"/"queue_timing" — how long a project's most recent poll
    # cycle actually took (see poll_project_ci / poll_project_queues).
    # Always overwrites: project + kind is the whole key (Observation#key),
    # so Store#record just keeps whichever cycle finished most recently —
    # no "checking" placeholder needed here the way branches/destinations
    # need one, since the widget hides a stale duration itself (Panel.qml
    # only reads it once its section's own loading state has cleared).
    def record_timing(project, kind, source, duration)
      @store.record(Observation.new(
                      project: project,
                      kind: kind,
                      branch: nil,
                      destination: nil,
                      version: nil,
                      state: "ok",
                      details: { duration_seconds: duration.round(1) },
                      timestamp: Time.now,
                      author: nil,
                      source: source,
                      observed_at: Time.now
                    ))
    end

    # GitHub's own UI treats a run with only skipped jobs as green, not as
    # partially failed — skips don't count against the total the way a
    # failure would. jobs_passed + jobs_skipped can be less than jobs_total
    # when something actually failed.
    def job_counts(jobs)
      jobs = Array(jobs)
      {
        jobs_total: jobs.size,
        jobs_passed: jobs.count { |job| job[:conclusion] == "success" },
        jobs_skipped: jobs.count { |job| job[:conclusion] == "skipped" }
      }
    end

    def poll_project_queues(path)
      repo = GitRepo.new(path)
      owner, name = repo.owner_and_repo
      project = "#{owner}/#{name}"
      started = Time.now

      destinations = @kamal_source.destinations(path)
      # A destination the store has never seen gets a "checking" row the
      # instant it's discovered — reading Kamal's destinations is a local
      # file read (Sources::Kamal), effectively free, unlike the real
      # check that follows (an SSH round-trip, seconds to tens of seconds
      # per destination). Without this, a project's queues render
      # identically to "nothing configured" for as long as its slowest
      # destination takes to answer — worst case, that's the very first
      # thing the widget has to show right after the collector starts.
      # Written immediately, before the slow checks below, instead of
      # waiting for the whole cycle to finish like poll_ci_once does.
      announce_new_destinations(project, destinations)
      announce_new_deploys(project, destinations)
      write_snapshot

      poll_destinations_concurrently(path, project, destinations)
      # Only when there was something to time — a project with zero
      # destinations has nothing real to report a duration for.
      record_timing(project, "queue_timing", "kamal-exec", Time.now - started) if destinations.any?
      write_snapshot
    rescue GitRepo::NoGithubRemoteError => e
      log("skipping queues for #{path}: #{e.message}")
    end

    # Same fix as poll_branches_concurrently, same reason: kamal app exec
    # is a real SSH round-trip per destination (Sources::Queue shells out
    # via a fresh Open3.capture3 every call, no shared connection object —
    # as safe to run concurrently as GithubClient's fresh Net::HTTP.start
    # per call). Uses the same MAX_CONCURRENT_REQUESTS cap for consistency,
    # even though a project's destination count is realistically small
    # (production/staging/etc.) and nowhere near where this would bite the
    # way an unbounded broad-mode branch poll could.
    def poll_destinations_concurrently(path, project, destinations)
      work_concurrently(destinations) do |destination|
        poll_destination_queue(path, project, destination)
      rescue StandardError => e
        log("#{project}@#{destination}: queue poll failed, skipping this cycle (#{e.class}: #{e.message})")
      end
      # A second full pass, not merged into the loop above — kamal app
      # version and kamal app exec are two separate SSH round-trips
      # regardless, and keeping them as two passes (like CI/queue stay
      # two entirely separate concerns everywhere else in this file)
      # reads clearer than one task doing two unrelated things. Measured
      # live rather than guessed at: merging wouldn't actually help when
      # a project's destination count sits under max_concurrent_requests
      # (the common case) — the critical path is still (that project's
      # slowest queue check) + (its slowest deploy check) either way,
      # whichever destination each happens to land on. `kamal app
      # version` itself is cheap (~1s for two destinations, confirmed
      # live) — a slow cycle is a slow queue check, same as before this.

      work_concurrently(destinations) do |destination|
        poll_destination_deploy(path, project, destination)
      rescue StandardError => e
        log("#{project}@#{destination}: deploy poll failed, skipping this cycle (#{e.class}: #{e.message})")
      end
    end

    # A fixed-size worker pool draining a shared Queue, not "spawn N
    # threads, join them" in batches of max_concurrent_requests — the
    # difference matters once items.size exceeds the cap: batching would
    # still start every batch fresh, so one slow item stalls an otherwise-
    # idle worker until its whole batch finishes. A shared queue means a
    # worker that finishes early immediately picks up the next item
    # instead of waiting on its batch-mates. Each item's own error
    # handling lives in the block the caller passes in (see
    # poll_branches_concurrently/poll_destinations_concurrently) — this
    # method doesn't rescue anything itself.
    def work_concurrently(items)
      return if items.empty?

      queue = Queue.new
      items.each { |item| queue << item }
      worker_count = [items.size, @max_concurrent_requests].min
      worker_count.times { queue << :done }

      Array.new(worker_count) do
        Thread.new do
          while (item = queue.pop) != :done
            yield item
          end
        end
      end.each(&:join)
    end

    def announce_new_destinations(project, destinations)
      destinations.each do |destination|
        pending = pending_queue_observation(project, destination)
        # Only for a destination the store has no data for at all — every
        # cycle re-announcing an already-known one would flash real data
        # back to "checking" on each poll, since Store#record always keeps
        # whichever observation's timestamp is newer and this one's is
        # always "now".
        next if @store.known?(pending.key)

        @store.record(pending)
      end
    end

    def pending_queue_observation(project, destination)
      Observation.new(
        project: project,
        kind: "queue",
        branch: nil,
        destination: destination,
        version: nil,
        state: "checking",
        details: {},
        # Epoch, not Time.now — see pending_ci_observation's comment. The
        # real queue check also happens to stamp Time.now today, so this
        # isn't live yet as a bug here specifically, but a placeholder
        # should never depend on the real observation's timestamp
        # semantics staying that way to be superseded correctly.
        timestamp: Time.at(0),
        author: nil,
        source: "kamal-exec",
        observed_at: Time.now
      )
    end

    # Same shape as announce_new_destinations/pending_queue_observation —
    # kept as its own pair rather than folded together, matching how CI
    # and queue stay two fully separate concerns even though they can
    # share a destination.
    def announce_new_deploys(project, destinations)
      destinations.each do |destination|
        pending = pending_deploy_observation(project, destination)
        next if @store.known?(pending.key)

        @store.record(pending)
      end
    end

    def pending_deploy_observation(project, destination)
      Observation.new(
        project: project,
        kind: "deploy",
        branch: nil,
        destination: destination,
        version: nil,
        state: "checking",
        details: {},
        timestamp: Time.at(0),
        author: nil,
        source: "kamal-version",
        observed_at: Time.now
      )
    end

    def poll_destination_queue(path, project, destination)
      counts = @queue_source.status(project_path: path, destination: destination)
      log("#{project}@#{destination} queue: ready=#{counts[:ready]} failed=#{counts[:failed]}")

      record_queue_observation(project, destination, state: queue_state(counts), details: counts)
    rescue Sources::Queue::CommandFailedError => e
      log("#{project}@#{destination} queue check failed: #{e.message}")
      # A skipped row looks identical to one nobody's checked yet — the
      # widget can't tell "SSH is broken" from "no data so far" without
      # this. Truncated: a full stderr dump doesn't belong in the state file.
      record_queue_observation(project, destination,
                               state: "unreachable", details: { error: e.message[0, 300] })
    end

    # "stalled": jobs are waiting (ready > 0) with nobody alive to work
    # them (workers == 0) — genuinely different from "failing" (a job
    # actually threw) and from what this used to report for it, "ok"
    # (only ever "failing" or "ok" before this: a backlog with zero
    # workers silently read as fine, since nothing had technically failed
    # yet — the widget's own status dot showed green for it). "failing"
    # still wins if both are somehow true at once — an actual failure is
    # the more urgent fact.
    #
    # counts[:workers] == 0, not counts[:workers].to_i.zero? — a missing
    # workers key (an older observation, or a queue_source that doesn't
    # report it) means "unknown", not "confirmed zero"; nil == 0 is
    # false, so it falls through to "ok" rather than claiming stalled on
    # data that was never actually collected.
    def queue_state(counts)
      return "failing" if counts[:failed].positive?
      # rubocop:disable Style/NumericPredicate -- .zero? would raise on a
      # missing key (nil); == 0 needs nil to compare false, not crash.
      return "stalled" if counts[:ready].positive? && counts[:workers] == 0
      # rubocop:enable Style/NumericPredicate

      "ok"
    end

    def record_queue_observation(project, destination, state:, details:)
      record_and_notify(Observation.new(
                          project: project,
                          kind: "queue",
                          branch: nil,
                          destination: destination,
                          version: nil,
                          state: state,
                          details: details,
                          timestamp: Time.now,
                          author: nil,
                          source: "kamal-exec",
                          observed_at: Time.now
                        ))
    end

    # "ok"/"unreachable" only for now — comparing this SHA against what
    # CI already verified for the same destination (to say "3 behind
    # main" instead of just "here's a SHA") is a separate, later piece,
    # not this one.
    def poll_destination_deploy(path, project, destination)
      sha = @deploy_source.version(project_path: path, destination: destination)
      log("#{project}@#{destination} deploy: #{sha}")

      record_deploy_observation(project, destination, state: "ok", version: sha,
                                                      details: deploy_freshness_details(path, project, sha))
    rescue Sources::Deploy::CommandFailedError, Sources::Deploy::NoVersionFoundError => e
      log("#{project}@#{destination} deploy check failed: #{e.message}")
      record_deploy_observation(project, destination, state: "unreachable", details: { error: e.message[0, 300] })
    end

    # Not which branch a destination "belongs to" (Kamal has no notion of
    # that) — is the SHA just deployed a real ancestor of any branch CI
    # currently has a result for, in the local clone already on disk? See
    # DeployFreshness's own comment for why the nearest match wins when
    # more than one branch qualifies.
    def deploy_freshness_details(path, project, deployed_sha)
      branch_shas = @store.entries_for(project: project, kind: "ci")
                          .filter_map { |observation| [observation.branch, observation.version] if observation.version }
                          .to_h
      return {} if branch_shas.empty?

      result = DeployFreshness.new(path).compare(deployed_sha, branch_shas)
      return {} unless result

      { fresh_branch: result.branch, behind: result.behind }
    end

    def record_deploy_observation(project, destination, state:, version: nil, details: {})
      record_and_notify(Observation.new(
                          project: project,
                          kind: "deploy",
                          branch: nil,
                          destination: destination,
                          version: version,
                          state: state,
                          details: details,
                          timestamp: Time.now,
                          author: nil,
                          source: "kamal-version",
                          observed_at: Time.now
                        ))
    end

    # Every *real* CI/queue result (never the "checking" placeholder or the
    # ci_timing/queue_timing rows — those go through @store.record
    # directly) passes through here, so a state change can be compared
    # against whatever it's replacing before it's gone.
    def record_and_notify(observation)
      # Only the actual Hash read+write needs the lock — notify_on_transition
      # works off values already captured by this point, and shelling out
      # to omarchy-notification-send is exactly the kind of thing other
      # threads shouldn't have to wait on.
      previous = @store_mutex.synchronize do
        prev = @store.current(observation.key)
        @store.record(observation)
        prev
      end
      notify_on_transition(observation, previous)
    end

    # A desktop notification only for an actual transition between two
    # *real* results — not the first result ever seen for a branch/
    # destination (previous is nil, or still the "checking" placeholder:
    # nothing to compare against yet, and "this thing that's always been
    # broken is broken" isn't news), and not a no-op poll that reports the
    # same state again (previous.state == observation.state). "no_runs" is
    # a real prior result despite not being a check — a branch going from
    # "nothing has ever run" to "it just failed" is exactly the kind of
    # change worth surfacing.
    def notify_on_transition(observation, previous)
      return if previous.nil? || previous.state == "checking"
      return if previous.state == observation.state

      was_bad = Observation.bad_state?(previous.state)
      now_bad = Observation.bad_state?(observation.state)
      return if was_bad == now_bad

      location = observation.kind == "ci" ? observation.branch : observation.destination
      # Was a plain CI/queue binary before "deploy" existed — a deploy
      # transition would have silently labeled itself "queue" otherwise.
      what = case observation.kind
             when "ci" then "CI"
             when "deploy" then "deploy"
             else "queue"
             end
      headline = "Owlook — #{observation.project}"

      if now_bad
        @notifier.notify(headline, "#{what} #{location}: #{observation.state.tr('_', ' ')}",
                         urgency: "critical")
      else
        @notifier.notify(headline, "#{what} #{location} back to normal", urgency: "normal")
      end
    end

    def write_snapshot
      snapshot = @store.snapshot
      return if snapshot.empty?

      log("wrote #{snapshot.size} row(s) to state file") if @writer.write(snapshot)
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
