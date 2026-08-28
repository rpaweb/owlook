# frozen_string_literal: true

require "open3"
require "json"
require "shellwords"

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
        def initialize(command, status, stderr)
          super("kamal app exec failed (exit #{status.exitstatus}): #{command.join(" ")}\n#{stderr}")
        end
      end

      # Backlog = ready_executions: jobs waiting for a worker right now.
      # Dead = failed_executions: jobs that failed and haven't been retried
      # or discarded. Targets the canonical solid_queue model names — a
      # custom fork with a different schema (like a project pinning
      # joshleblanc/solid_queue) may not match.
      RUNNER_CODE = "puts({ready: SolidQueue::ReadyExecution.count, " \
        "failed: SolidQueue::FailedExecution.count}.to_json)"

      DEFAULT_SHELL = lambda do |command, chdir:|
        stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
        raise CommandFailedError.new(command, status, stderr) unless status.success?

        stdout
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
        # identical JSON line per role, not a single line.
        data = JSON.parse(output.lines.first.to_s)
        { ready: data.fetch("ready"), failed: data.fetch("failed") }
      end
    end
  end
end
