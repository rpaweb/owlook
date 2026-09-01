# frozen_string_literal: true

require "test_helper"

class Owlook::Sources::SSHAgentTest < Minitest::Test
  def test_resolve_auth_sock_prefers_the_env_var
    sock = Owlook::Sources::SSHAgent.resolve_auth_sock(
      env: { "SSH_AUTH_SOCK" => "/run/user/1000/explicit.sock" },
      socket_exists: ->(_path) { flunk "should not need to check a fallback when the env var is set" }
    )

    assert_equal "/run/user/1000/explicit.sock", sock
  end

  def test_resolve_auth_sock_falls_back_to_the_gpg_agent_ssh_socket
    sock = Owlook::Sources::SSHAgent.resolve_auth_sock(
      env: { "XDG_RUNTIME_DIR" => "/run/user/1000" },
      socket_exists: ->(path) { path == "/run/user/1000/gnupg/S.gpg-agent.ssh" }
    )

    assert_equal "/run/user/1000/gnupg/S.gpg-agent.ssh", sock
  end

  def test_resolve_auth_sock_returns_nil_when_nothing_is_available
    sock = Owlook::Sources::SSHAgent.resolve_auth_sock(
      env: { "XDG_RUNTIME_DIR" => "/run/user/1000" },
      socket_exists: ->(_path) { false }
    )

    assert_nil sock
  end
end
