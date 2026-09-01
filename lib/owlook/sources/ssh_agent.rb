# frozen_string_literal: true

module Owlook
  module Sources
    # Shared by Sources::Queue and Sources::Deploy — both shell out to
    # `kamal` over SSH from a systemd --user process, which doesn't
    # inherit SSH_AUTH_SOCK from the desktop session (confirmed
    # empirically: `systemctl --user show-environment` has no such entry
    # even in a live session with a working agent). gpg-agent's SSH
    # support listens on a fixed, well-known path under $XDG_RUNTIME_DIR
    # (confirmed present as a real, active `gpg-agent-ssh.socket` systemd
    # unit on a real machine) rather than a randomly-generated one, so it
    # can be reached without inheriting anything. Only a fallback: an
    # explicit SSH_AUTH_SOCK always wins, and a different agent (plain
    # ssh-agent, 1Password, etc.) still needs the user's own setup to
    # expose it — this doesn't invent unlocking a key, only reaching an
    # agent that already has one unlocked.
    #
    # One resolver, not a copy per source — Sources::Deploy needing the
    # exact same lookup Sources::Queue already had is what pulled this
    # out, rather than starting a second copy that could drift from the
    # first the way Observation::BAD_STATES and Model.js's BAD_STATES
    # already have to be kept in sync by hand.
    module SSHAgent
      def self.resolve_auth_sock(env: ENV, socket_exists: ->(path) { File.socket?(path) })
        explicit = env["SSH_AUTH_SOCK"]
        return explicit if explicit && !explicit.empty?

        runtime_dir = env.fetch("XDG_RUNTIME_DIR", "/run/user/#{Process.uid}")
        fallback = File.join(runtime_dir, "gnupg", "S.gpg-agent.ssh")
        fallback if socket_exists.call(fallback)
      end
    end
  end
end
