# frozen_string_literal: true

require "time"

module Owlook
  # Wires config -> git -> github source -> store -> state file for one poll
  # cycle. #run is the infinite loop the systemd unit calls; all the actual
  # logic lives in #poll_once so it can be tested without looping or sleeping.
  #
  # NOTE — open design question, not resolved here: this maps a GitHub
  # Actions run onto an Observation using the run's *branch* as the
  # `destination`, not a real Kamal destination. v1 has no other source that
  # reports a destination (Kamal hooks/SSH are explicitly out of scope), so
  # there is nothing to correlate a run against yet. If/when a real
  # per-destination source is added, this mapping needs revisiting — flagging
  # explicitly rather than guessing a branch->destination convention.
  class Collector
    def initialize(config:, store:, writer:, github_source:, logger: nil)
      @config = config
      @store = store
      @writer = writer
      @github_source = github_source
      @logger = logger
    end

    def poll_once
      @config.projects.each { |path| poll_project(path) }
      snapshot = @store.snapshot
      return if snapshot.empty?

      log("wrote #{snapshot.size} project(s) to state file") if @writer.write(snapshot)
    end

    def run(interval:)
      loop do
        poll_once
        sleep interval
      end
    end

    private

    def poll_project(path)
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
        destination: branch,
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

    def log(message)
      @logger&.call(message)
    end
  end
end
