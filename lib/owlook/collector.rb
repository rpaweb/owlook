# frozen_string_literal: true

require "time"

module Owlook
  # Wires config -> git/kamal -> sources -> store -> state file. #run is the
  # infinite loop the systemd unit calls; all the actual logic lives in
  # #poll_ci_once / #poll_queues_once so it can be tested without looping or
  # sleeping.
  #
  # Two cadences, not one: GitHub Actions is a free API call, safe every 30s.
  # A queue check is a real SSH round-trip (kamal app exec), so it runs on
  # its own, slower interval — #run takes both separately.
  #
  # GitHub Actions produces "ci" observations, identified by project +
  # branch (see Observation#key) — never a "deploy" observation, since
  # nothing in v1 reports a real Kamal destination (hooks/SSH are out of
  # scope). Queue checks produce "queue" observations, identified by project
  # + destination — a queue backlog belongs to a deployed environment, not a
  # branch, so it needs Sources::Kamal to know which destinations exist.
  class Collector
    # config_loader is a callable (e.g. -> { Owlook::Config.load(path) }),
    # not a static Config — called fresh on every poll rather than once at
    # construction, so editing config.yml takes effect on the next cycle
    # (well within 30s) instead of needing a systemd restart.
    # sleeper is injectable (real default: Kernel#sleep) purely so
    # #wait_for_next_poll is testable without an actual test waiting out a
    # real interval — see its own comment.
    def initialize(config_loader:, store:, writer:, github_source:,
      kamal_source: Sources::Kamal.new, queue_source: Sources::Queue.new,
      workflows_source: Sources::Workflows.new,
      settings_loader: -> { WidgetSettings.load },
      sleeper: ->(seconds) { sleep(seconds) }, logger: nil)
      @config_loader = config_loader
      @store = store
      @writer = writer
      @github_source = github_source
      @kamal_source = kamal_source
      @queue_source = queue_source
      @workflows_source = workflows_source
      @settings_loader = settings_loader
      @sleeper = sleeper
      @logger = logger
    end

    def poll_ci_once
      projects.each { |path| poll_project_ci(path) }
      write_snapshot
    end

    def poll_queues_once
      projects.each { |path| poll_project_queues(path) }
    end

    def run(ci_interval:, queue_interval:)
      next_queue_check = Time.now
      loop do
        poll_ci_once
        if Time.now >= next_queue_check
          poll_queues_once
          next_queue_check = Time.now + queue_interval
        end
        wait_for_next_poll(ci_interval)
      end
    end

    private

    # Sleeps in short ticks instead of one flat call for the whole
    # interval, so flipping the widget's "all branches" toggle (written to
    # shell.json — see WidgetSettings) takes effect within about a second
    # instead of waiting out the rest of a 30s interval. A config.yml edit
    # is made ahead of time with nobody watching, so a slow reload there
    # is fine; a toggle is clicked with the panel open, and nothing
    # visibly happening for up to 30s reads as broken.
    def wait_for_next_poll(ci_interval, tick: 1)
      baseline = @settings_loader.call.all_branches?
      elapsed = 0
      while elapsed < ci_interval
        step = [tick, ci_interval - elapsed].min
        @sleeper.call(step)
        elapsed += step
        break if @settings_loader.call.all_branches? != baseline
      end
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

      branches_to_poll(path, repo, owner, name).each { |branch| poll_branch_ci(owner, name, project, branch) }
    rescue GitRepo::NoGithubRemoteError => e
      log("skipping #{path}: #{e.message}")
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
        version: run[:head_sha], details: job_counts(run[:jobs]),
        timestamp: Time.parse(run[:updated_at]), author: run[:actor])
    end

    def record_ci_observation(project, branch, state:, version:, details:, timestamp:, author:)
      @store.record(Observation.new(
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
      write_snapshot

      destinations.each { |destination| poll_destination_queue(path, project, destination) }
      write_snapshot
    rescue GitRepo::NoGithubRemoteError => e
      log("skipping queues for #{path}: #{e.message}")
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
        timestamp: Time.now,
        author: nil,
        source: "kamal-exec",
        observed_at: Time.now
      )
    end

    def poll_destination_queue(path, project, destination)
      counts = @queue_source.status(project_path: path, destination: destination)
      log("#{project}@#{destination} queue: ready=#{counts[:ready]} failed=#{counts[:failed]}")

      record_queue_observation(project, destination,
        state: counts[:failed].positive? ? "failing" : "ok", details: counts)
    rescue Sources::Queue::CommandFailedError => e
      log("#{project}@#{destination} queue check failed: #{e.message}")
      # A skipped row looks identical to one nobody's checked yet — the
      # widget can't tell "SSH is broken" from "no data so far" without
      # this. Truncated: a full stderr dump doesn't belong in the state file.
      record_queue_observation(project, destination,
        state: "unreachable", details: { error: e.message[0, 300] })
    end

    def record_queue_observation(project, destination, state:, details:)
      @store.record(Observation.new(
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
