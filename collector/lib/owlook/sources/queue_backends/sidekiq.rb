# frozen_string_literal: true

module Owlook
  module Sources
    module QueueBackends
      # Sidekiq is far more common in the real Rails ecosystem than Solid
      # Queue — this exists specifically so a project doesn't have to be
      # ported off Sidekiq (or lie to owlook) just to get queue tracking.
      module Sidekiq
        def self.detect?(project_path)
          lockfile = File.join(project_path, "Gemfile.lock")
          File.exist?(lockfile) && File.read(lockfile).match?(/^ {4}sidekiq \(/)
        end

        # Mapped to Sidekiq's own real API (confirmed against the actual
        # installed gem, not guessed):
        #   ready   -> Sidekiq::Queue.all.sum(&:size) — every queue, not
        #              just "default"; a project routing work across
        #              several named queues would otherwise silently
        #              undercount.
        #   failed  -> Sidekiq::DeadSet#size, not RetrySet#size — a dead
        #              job exhausted its retries and needs a human, the
        #              same "actually failed" meaning Solid Queue's own
        #              FailedExecution has; a job still in RetrySet is
        #              working as designed, not a failure yet.
        #   workers -> Sidekiq::ProcessSet#size, which prunes stale
        #              entries (no heartbeat in 60s) in its own
        #              initializer before counting — confirmed in the
        #              gem source, not assumed from the method name alone.
        #   oldest  -> Sidekiq::Queue#latency is already exactly this:
        #              seconds since the oldest job in that queue was
        #              enqueued. Max across queues, only when something's
        #              actually ready — same "no fake zero" reasoning as
        #              Solid Queue's own oldest.
        #
        # `require "sidekiq/api"` is not optional — confirmed live against
        # a real production Rails app (nycbirdalliance): plain `gem
        # "sidekiq"` does not autoload it (Sidekiq::Queue and friends live
        # in a separate file the main gem entry point never requires), so
        # without this line every one of these constants raises
        # `uninitialized constant` the moment a project doesn't also pull
        # in Sidekiq::Web or another gem that happens to require it first.
        RUNNER_CODE = <<~RUBY.strip
          require "sidekiq/api"
          queues = Sidekiq::Queue.all
          result = {
            ready: queues.sum(&:size),
            failed: Sidekiq::DeadSet.new.size,
            workers: Sidekiq::ProcessSet.new.size
          }
          result[:oldest] = queues.map(&:latency).max.round if result[:ready].positive?
          puts result.to_json
        RUBY
      end
    end
  end
end
