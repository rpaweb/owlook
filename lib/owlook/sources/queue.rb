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

      DEFAULT_SHELL = lambda do |command, chdir:|
        env = {}
        sock = resolve_ssh_auth_sock
        env["SSH_AUTH_SOCK"] = sock if sock

        stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
        raise CommandFailedError.new(command, status, stderr) unless status.success?

        stdout
      end

      # `systemctl --user`'s manager environment does not inherit
      # SSH_AUTH_SOCK from the desktop session (confirmed empirically:
      # `systemctl --user show-environment` has no such entry even in a
      # live session with a working agent) — a systemd --user unit like the
      # collector's needs to find it another way. gpg-agent's SSH support
      # listens on a fixed, well-known path under $XDG_RUNTIME_DIR
      # (confirmed present as a real, active `gpg-agent-ssh.socket` systemd
      # unit on a real machine) rather than a randomly-generated one, so it
      # can be reached without inheriting anything. Only a fallback: an
      # explicit SSH_AUTH_SOCK always wins, and a different agent (plain
      # ssh-agent, 1Password, etc.) still needs the user's own setup to
      # expose it — this doesn't invent unlocking a key, only reaching an
      # agent that already has one unlocked.
      def self.resolve_ssh_auth_sock(env: ENV, socket_exists: ->(path) { File.socket?(path) })
        explicit = env["SSH_AUTH_SOCK"]
        return explicit if explicit && !explicit.empty?

        runtime_dir = env.fetch("XDG_RUNTIME_DIR", "/run/user/#{Process.uid}")
        fallback = File.join(runtime_dir, "gnupg", "S.gpg-agent.ssh")
        fallback if socket_exists.call(fallback)
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
        result = { ready: data.fetch("ready"), failed: data.fetch("failed") }
        # workers/oldest are read defensively rather than with fetch: an
        # older RUNNER_CODE (already-running collector mid-deploy, or a
        # stubbed test fixture) may not have sent them yet.
        result[:workers] = data["workers"] if data.key?("workers")
        result[:oldest] = data["oldest"] if data.key?("oldest")
        result
      end
    end
  end
end
