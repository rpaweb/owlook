# frozen_string_literal: true

require_relative "ssh_agent"

module Owlook
  module Sources
    # Reads the git SHA Kamal considers currently deployed to a
    # destination via `kamal app version` — the exact read-only command a
    # developer already runs by hand to check what's live; the collector
    # just calls it on a schedule. Zero new credentials, same reason as
    # Sources::Queue: reuses whatever SSH access already works for
    # `kamal deploy` itself.
    #
    # `shell` is injectable so tests never touch the network — same
    # SSHAgent-backed exec as Sources::Queue, never a hand-rolled SSH
    # implementation.
    class Deploy
      class CommandFailedError < StandardError
        # status is nil for a BoundedCommand timeout/output-cap hit — see
        # Sources::Queue::CommandFailedError's identical comment for why
        # this still needs to be *this* error class specifically, not a
        # plain StandardError.
        def initialize(command, status, stderr)
          reason = status ? "exit #{status.exitstatus}" : "timed out or produced too much output"
          super("kamal app version failed (#{reason}): #{command.join(' ')}\n#{stderr}")
        end
      end

      class NoVersionFoundError < StandardError
        def initialize(output)
          super("no git SHA found in kamal app version output:\n#{output}")
        end
      end

      # BoundedCommand, not a raw Open3.capture3 — same reasoning as
      # Sources::Queue's DEFAULT_SHELL: this is a network call to a
      # destination this process doesn't control, and Open3.capture3
      # neither times out nor caps how much it buffers.
      # timeout/max_bytes default to BoundedCommand's own — exposed here
      # only so a test can force a fast timeout/output-cap hit without
      # waiting out the real 30s default.
      DEFAULT_SHELL = lambda do |command, chdir:, timeout: BoundedCommand::DEFAULT_TIMEOUT,
                                  max_bytes: BoundedCommand::DEFAULT_MAX_BYTES|
        env = {}
        sock = SSHAgent.resolve_auth_sock
        env["SSH_AUTH_SOCK"] = sock if sock

        begin
          result = BoundedCommand.run(*command, chdir: chdir, env: env, timeout: timeout, max_bytes: max_bytes)
        rescue BoundedCommand::TimeoutError, BoundedCommand::OutputTooLargeError => e
          raise CommandFailedError.new(command, nil, e.message)
        end
        raise CommandFailedError.new(command, result.status, result.stderr) unless result.status.success?

        result.stdout
      end

      def initialize(shell: DEFAULT_SHELL)
        @shell = shell
      end

      def version(project_path:, destination:)
        output = @shell.call(build_command(destination), chdir: project_path)
        parse(output)
      end

      private

      def build_command(destination)
        command = %w[kamal app version]
        command += ["--destination", destination] unless destination == "default"
        command
      end

      # Real output (confirmed live, not guessed) mixes "INFO [...]
      # Running/Finished..." log lines and an "App Host: <ip>" line in
      # with the one line that actually matters — a bare 40-character git
      # SHA. Scan for the line shaped like a SHA instead of assuming
      # position, same reason Sources::Queue does this for its own
      # output. A multi-host destination reports one SHA line per host;
      # taking the first is the same simplification Sources::Queue makes
      # for a multi-role destination's repeated JSON lines.
      def parse(output)
        sha = output.each_line.map(&:strip).find { |line| line.match?(/\A[0-9a-f]{40}\z/) }
        raise NoVersionFoundError, output unless sha

        sha
      end
    end
  end
end
