# frozen_string_literal: true

require "open3"
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
        def initialize(command, status, stderr)
          super("kamal app version failed (exit #{status.exitstatus}): #{command.join(' ')}\n#{stderr}")
        end
      end

      class NoVersionFoundError < StandardError
        def initialize(output)
          super("no git SHA found in kamal app version output:\n#{output}")
        end
      end

      DEFAULT_SHELL = lambda do |command, chdir:|
        env = {}
        sock = SSHAgent.resolve_auth_sock
        env["SSH_AUTH_SOCK"] = sock if sock

        stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
        raise CommandFailedError.new(command, status, stderr) unless status.success?

        stdout
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
