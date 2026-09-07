# frozen_string_literal: true

require "json"
require "shellwords"
require_relative "ssh_agent"

module Owlook
  module Sources
    # Reads Solid Queue backlog/dead-job counts for a deployed destination by
    # running `bin/rails runner` inside the *already-running* production
    # container over SSH (`kamal app exec --reuse`) — reuses whatever SSH
    # access the developer already has for `kamal deploy` itself, and needs
    # zero code added to the target Rails app (Solid Queue's own model
    # classes already exist once the gem is installed).
    #
    # `shell` is injectable so tests never touch the network; the real
    # default shells out to the `kamal` CLI via Open3, never a hand-rolled
    # SSH implementation.
    class Queue
      class CommandFailedError < StandardError
        # status is nil for a BoundedCommand timeout/output-cap hit —
        # there's no real exit status for a process this killed rather
        # than let finish. Collector's rescue Queue::CommandFailedError
        # (not a plain StandardError) is what turns any of this into the
        # "unreachable" state the panel actually shows; a distinct,
        # uncaught error class here would instead leave the destination
        # on its "checking" placeholder forever, silently — the same bug
        # class BoundedCommand's own timeout exists to prevent, just
        # moved one layer up.
        def initialize(command, status, stderr)
          reason = status ? "exit #{status.exitstatus}" : "timed out or produced too much output"
          super("kamal app exec failed (#{reason}): #{command.join(' ')}\n#{stderr}")
        end
      end

      # Backlog = ready_executions: jobs waiting for a worker right now.
      # Dead = failed_executions: jobs that failed and haven't been retried
      # or discarded. workers = processes Solid Queue itself still
      # considers alive (SolidQueue.process_alive_threshold, 5 minutes by
      # default — confirmed against the installed gem — rather than a
      # guessed constant, so this tracks whatever the target app actually
      # configured). oldest is the age in seconds of the longest-waiting
      # ready job, omitted entirely when nothing's waiting — there's no
      # "oldest" to report with zero ready jobs, and a fake zero there
      # would read as "the queue just started", not "empty". Targets the
      # canonical solid_queue model names — a custom fork with a different
      # schema (like a project pinning joshleblanc/solid_queue) may not
      # match.
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

      # BoundedCommand, not a raw Open3.capture3: this runs over SSH
      # against a destination this process doesn't control, and
      # Open3.capture3 has no timeout and no cap on how much it'll
      # buffer — a hostile or merely hung target wedges the whole
      # collector cycle, or exhausts memory reading its output.
      # timeout/max_bytes default to BoundedCommand's own — exposed here
      # only so a test can force a fast timeout/output-cap hit without
      # waiting out the real 30s default.
      DEFAULT_SHELL = lambda do |command, chdir:, timeout: BoundedCommand::DEFAULT_TIMEOUT,
                                  max_bytes: BoundedCommand::DEFAULT_MAX_BYTES|
        env = {}
        sock = resolve_ssh_auth_sock
        env["SSH_AUTH_SOCK"] = sock if sock

        begin
          result = BoundedCommand.run(*command, chdir: chdir, env: env, timeout: timeout, max_bytes: max_bytes)
        rescue BoundedCommand::TimeoutError, BoundedCommand::OutputTooLargeError => e
          raise CommandFailedError.new(command, nil, e.message)
        end
        raise CommandFailedError.new(command, result.status, result.stderr) unless result.status.success?

        result.stdout
      end

      # Delegates to SSHAgent — Sources::Deploy needs the identical
      # lookup, so it moved there rather than staying a copy. Kept here,
      # under its original name, so nothing calling Queue.resolve_ssh_auth_sock
      # directly (including this class's own DEFAULT_SHELL) has to change.
      def self.resolve_ssh_auth_sock(env: ENV, socket_exists: ->(path) { File.socket?(path) })
        SSHAgent.resolve_auth_sock(env: env, socket_exists: socket_exists)
      end

      def initialize(shell: DEFAULT_SHELL)
        @shell = shell
      end

      def status(project_path:, destination:)
        output = @shell.call(build_command(destination), chdir: project_path)
        parse(output)
      end

      private

      def build_command(destination)
        command = ["kamal", "app", "exec", "--reuse", "--raw"]
        command += ["--destination", destination] unless destination == "default"
        # Kamal::Utils.join_commands (verified by reading the gem source) is
        # a naive `commands.join(" ")` — no shell-escaping — and the result
        # ultimately runs through a shell on the remote host (SSH exec takes
        # one command string, not an argv array). Pre-escape our own
        # argument so it survives that reconstruction as one token.
        command + ["--", "bin/rails", "runner", Shellwords.escape(RUNNER_CODE)]
      end

      def parse(output)
        # --reuse runs the command on every role matching the destination,
        # not just one (confirmed against a real multi-role project) — one
        # identical JSON line per role. output.lines.first used to be
        # trusted as that JSON outright — broke against a real target app
        # with verbose query logging on (confirmed live: ANSI-colored SQL
        # log lines from every SolidQueue.* call print ahead of the real
        # `puts result.to_json`, so the first line is a log line, not
        # data, whenever that's on). Scan for the first line that's
        # actually our JSON shape instead of assuming position.
        data = first_result_line(output)
        raise JSON::ParserError, "no queue-check JSON found in output" unless data

        result = { ready: data.fetch("ready"), failed: data.fetch("failed") }
        # workers/oldest are read defensively rather than with fetch: an
        # older RUNNER_CODE (already-running collector mid-deploy, or a
        # stubbed test fixture) may not have sent them yet.
        result[:workers] = data["workers"] if data.key?("workers")
        result[:oldest] = data["oldest"] if data.key?("oldest")
        result
      end

      def first_result_line(output)
        output.each_line do |line|
          parsed = JSON.parse(line)
          return parsed if parsed.is_a?(Hash) && parsed.key?("ready") && parsed.key?("failed")
        rescue JSON::ParserError
          next
        end
        nil
      end
    end
  end
end
