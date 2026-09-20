# frozen_string_literal: true

module Owlook
  module Sources
    module QueueBackends
      # The original, and still the default when nothing more specific is
      # detected — see Sources::Queue#detect_backend for why "detected
      # nothing" falls back here instead of raising: every project this
      # ever ran against before backend detection existed was assumed to
      # be Solid Queue, so keeping that as the fallback is the only way
      # this generalization doesn't change behavior for a single existing
      # user.
      module SolidQueue
        # Solid Queue ships as part of Rails' own default Gemfile since
        # 8.0 — detecting it isn't what decides whether to use this
        # backend (it's the fallback regardless), only whether a project
        # is unambiguously *not* a Sidekiq one is decided elsewhere.
        def self.detect?(project_path)
          lockfile = File.join(project_path, "Gemfile.lock")
          File.exist?(lockfile) && File.read(lockfile).match?(/^ {4}solid_queue \(/)
        end

        # Backlog = ready_executions: jobs waiting for a worker right now.
        # Dead = failed_executions: jobs that failed and haven't been
        # retried or discarded. workers = processes Solid Queue itself
        # still considers alive (SolidQueue.process_alive_threshold, 5
        # minutes by default — confirmed against the installed gem,
        # rather than a guessed constant, so this tracks whatever the
        # target app actually configured). oldest is the age in seconds
        # of the longest-waiting ready job, omitted entirely when
        # nothing's waiting — there's no "oldest" to report with zero
        # ready jobs, and a fake zero there would read as "the queue just
        # started", not "empty". Targets the canonical solid_queue model
        # names — a custom fork with a different schema (like a project
        # pinning joshleblanc/solid_queue) may not match.
        RUNNER_CODE = <<~RUBY.strip
          oldest_ready = SolidQueue::ReadyExecution.minimum(:created_at)
          result = {
            ready: SolidQueue::ReadyExecution.count,
            failed: SolidQueue::FailedExecution.count,
            workers: SolidQueue::Process.where("last_heartbeat_at > ?", SolidQueue.process_alive_threshold.ago).count
          }
          result[:oldest] = (Time.current - oldest_ready).round if oldest_ready
          puts result.to_json
        RUBY
      end
    end
  end
end
