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
    def initialize(config:, store:, writer:, github_source:,
      kamal_source: Sources::Kamal.new, queue_source: Sources::Queue.new, logger: nil)
      @config = config
      @store = store
      @writer = writer
      @github_source = github_source
      @kamal_source = kamal_source
      @queue_source = queue_source
      @logger = logger
    end

    def poll_ci_once
      @config.projects.each { |path| poll_project_ci(path) }
      write_snapshot
    end

    def poll_queues_once
      @config.projects.each { |path| poll_project_queues(path) }
      write_snapshot
    end

    def run(ci_interval:, queue_interval:)
      next_queue_check = Time.now
      loop do
        poll_ci_once
        if Time.now >= next_queue_check
          poll_queues_once
          next_queue_check = Time.now + queue_interval
        end
        sleep ci_interval
      end
    end

    private

    def poll_project_ci(path)
      repo = GitRepo.new(path)
      owner, name = repo.owner_and_repo
      branch = repo.current_branch

      run = @github_source.latest_run(owner: owner, repo: name, branch: branch)
      unless run
        log("#{owner}/#{name}@#{branch}: no workflow runs")
        return
      end

      log("#{owner}/#{name}@#{branch}: #{run[:conclusion] || run[:status]}")
      @store.record(Observation.new(
        project: "#{owner}/#{name}",
        kind: "ci",
        branch: branch,
        destination: nil,
        version: run[:head_sha],
        state: run[:conclusion] || run[:status],
        timestamp: Time.parse(run[:updated_at]),
        author: run[:actor],
        source: "github",
        observed_at: Time.now
      ))
    rescue GitRepo::NoGithubRemoteError => e
      log("skipping #{path}: #{e.message}")
    end

    def poll_project_queues(path)
      repo = GitRepo.new(path)
      owner, name = repo.owner_and_repo
      project = "#{owner}/#{name}"

      @kamal_source.destinations(path).each { |destination| poll_destination_queue(path, project, destination) }
    rescue GitRepo::NoGithubRemoteError => e
      log("skipping queues for #{path}: #{e.message}")
    end

    def poll_destination_queue(path, project, destination)
      counts = @queue_source.status(project_path: path, destination: destination)
      log("#{project}@#{destination} queue: ready=#{counts[:ready]} failed=#{counts[:failed]}")

      @store.record(Observation.new(
        project: project,
        kind: "queue",
        branch: nil,
        destination: destination,
        version: nil,
        state: counts[:failed].positive? ? "failing" : "ok",
        details: counts,
        timestamp: Time.now,
        author: nil,
        source: "kamal-exec",
        observed_at: Time.now
      ))
    rescue Sources::Queue::CommandFailedError => e
      log("#{project}@#{destination} queue check failed: #{e.message}")
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
