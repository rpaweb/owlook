# frozen_string_literal: true

require "test_helper"
require "shellwords"

class Owlook::Sources::QueueTest < Minitest::Test
  def test_status_parses_ready_and_failed_counts
    shell = FakeShell.new('{"ready":3,"failed":1}')
    source = Owlook::Sources::Queue.new(shell: shell)

    result = source.status(project_path: "/tmp/widgets", destination: "staging")

    assert_equal({ ready: 3, failed: 1 }, result)
  end

  def test_status_includes_workers_and_oldest_when_present
    shell = FakeShell.new('{"ready":5,"failed":1,"workers":2,"oldest":37}')
    source = Owlook::Sources::Queue.new(shell: shell)

    result = source.status(project_path: "/tmp/widgets", destination: "staging")

    assert_equal({ ready: 5, failed: 1, workers: 2, oldest: 37 }, result)
  end

  # RUNNER_CODE never sends "oldest" when nothing's ready (see its own
  # comment) — a fake zero there would read as "the queue just started"
  # rather than "nothing waiting to report an age for".
  def test_status_omits_oldest_when_nothing_is_ready
    shell = FakeShell.new('{"ready":0,"failed":3,"workers":1}')
    source = Owlook::Sources::Queue.new(shell: shell)

    result = source.status(project_path: "/tmp/widgets", destination: "staging")

    assert_equal({ ready: 0, failed: 3, workers: 1 }, result)
    refute result.key?(:oldest)
  end

  # A stubbed/older payload without workers or oldest at all still parses
  # cleanly — the two extra fields are read defensively, not with fetch.
  def test_status_still_works_without_workers_or_oldest_in_the_payload
    shell = FakeShell.new('{"ready":3,"failed":1}')
    source = Owlook::Sources::Queue.new(shell: shell)

    result = source.status(project_path: "/tmp/widgets", destination: "staging")

    assert_equal({ ready: 3, failed: 1 }, result)
  end

  # `kamal app exec --reuse` runs the command on every role matching the
  # destination, not just one (confirmed against a real multi-role project:
  # timeline-rails has "web" and "solid_queue" roles, and both answered) —
  # so --raw output is one identical JSON line per role, not a single line.
  def test_status_handles_one_json_line_per_role
    shell = FakeShell.new("{\"ready\":0,\"failed\":18}\n{\"ready\":0,\"failed\":18}\n")
    source = Owlook::Sources::Queue.new(shell: shell)

    result = source.status(project_path: "/tmp/widgets", destination: "staging")

    assert_equal({ ready: 0, failed: 18 }, result)
  end

  # A real target app with verbose query logging on prints an ANSI-colored
  # SQL log line for every SolidQueue.* call in RUNNER_CODE ahead of the
  # actual `puts result.to_json` — confirmed live against a real staging
  # environment. The first line isn't reliably the JSON; scan for it.
  def test_status_skips_query_log_noise_ahead_of_the_json
    log_line = "  \e[1m\e[36mSolidQueue::ReadyExecution Minimum (10.7ms)\e[0m  " \
               "\e[1m\e[34mSELECT MIN(\"solid_queue_ready_executions\".\"created_at\") " \
               "FROM \"solid_queue_ready_executions\"\e[0m"
    noisy = [log_line, '{"ready":0,"failed":30582,"workers":4}', ""].join("\n")
    shell = FakeShell.new(noisy)
    source = Owlook::Sources::Queue.new(shell: shell)

    result = source.status(project_path: "/tmp/widgets", destination: "staging")

    assert_equal({ ready: 0, failed: 30_582, workers: 4 }, result)
  end

  def test_status_raises_when_no_line_looks_like_the_expected_json
    shell = FakeShell.new("nothing but log noise, no result line at all\n")
    source = Owlook::Sources::Queue.new(shell: shell)

    assert_raises(JSON::ParserError) do
      source.status(project_path: "/tmp/widgets", destination: "staging")
    end
  end

  def test_status_runs_in_the_project_directory
    shell = FakeShell.new('{"ready":0,"failed":0}')
    source = Owlook::Sources::Queue.new(shell: shell)

    source.status(project_path: "/tmp/widgets", destination: "staging")

    assert_equal "/tmp/widgets", shell.last_chdir
  end

  def test_status_passes_destination_for_a_named_destination
    shell = FakeShell.new('{"ready":0,"failed":0}')
    source = Owlook::Sources::Queue.new(shell: shell)

    source.status(project_path: "/tmp/widgets", destination: "staging")

    assert_includes shell.last_command, "--destination"
    assert_includes shell.last_command, "staging"
  end

  def test_status_omits_destination_flag_for_default
    shell = FakeShell.new('{"ready":0,"failed":0}')
    source = Owlook::Sources::Queue.new(shell: shell)

    source.status(project_path: "/tmp/widgets", destination: "default")

    refute_includes shell.last_command, "--destination"
  end

  def test_status_uses_reuse_and_raw_so_output_is_parseable
    shell = FakeShell.new('{"ready":0,"failed":0}')
    source = Owlook::Sources::Queue.new(shell: shell)

    source.status(project_path: "/tmp/widgets", destination: "default")

    assert_includes shell.last_command, "--reuse"
    assert_includes shell.last_command, "--raw"
  end

  def test_status_raises_when_the_command_fails
    shell = FailingShell.new
    source = Owlook::Sources::Queue.new(shell: shell)

    assert_raises(Owlook::Sources::Queue::CommandFailedError) do
      source.status(project_path: "/tmp/widgets", destination: "default")
    end
  end

  # Kamal::Utils.join_commands (verified by reading the gem source) just
  # does `commands.join(" ")` — no shell-escaping at all — and that joined
  # string ultimately runs through a shell on the remote host (SSH exec
  # takes one command string, not an argv array). Without escaping, the
  # runner code's own `{`, `(`, `:` break as soon as the remote shell
  # re-parses it. This reproduces that reconstruction locally.
  def test_runner_code_survives_kamals_naive_space_join_and_a_shell_reparse
    shell = FakeShell.new('{"ready":0,"failed":0}')
    source = Owlook::Sources::Queue.new(shell: shell)

    source.status(project_path: "/tmp/widgets", destination: "default")

    reconstructed = Shellwords.split(shell.last_command.join(" "))

    assert_equal Owlook::Sources::Queue::RUNNER_CODE, reconstructed.last
  end

  def test_command_failed_error_includes_stderr_so_failures_are_debuggable
    error = Owlook::Sources::Queue::CommandFailedError.new(%w[kamal app exec], FakeStatus.new(1),
                                                           "No container found")

    assert_includes error.message, "No container found"
  end

  def test_resolve_ssh_auth_sock_prefers_the_env_var
    sock = Owlook::Sources::Queue.resolve_ssh_auth_sock(
      env: { "SSH_AUTH_SOCK" => "/run/user/1000/explicit.sock" },
      socket_exists: ->(_path) { flunk "should not need to check a fallback when the env var is set" }
    )

    assert_equal "/run/user/1000/explicit.sock", sock
  end

  def test_resolve_ssh_auth_sock_falls_back_to_the_gpg_agent_ssh_socket
    sock = Owlook::Sources::Queue.resolve_ssh_auth_sock(
      env: { "XDG_RUNTIME_DIR" => "/run/user/1000" },
      socket_exists: ->(path) { path == "/run/user/1000/gnupg/S.gpg-agent.ssh" }
    )

    assert_equal "/run/user/1000/gnupg/S.gpg-agent.ssh", sock
  end

  def test_resolve_ssh_auth_sock_returns_nil_when_nothing_is_available
    sock = Owlook::Sources::Queue.resolve_ssh_auth_sock(
      env: { "XDG_RUNTIME_DIR" => "/run/user/1000" },
      socket_exists: ->(_path) { false }
    )

    assert_nil sock
  end

  class FakeShell
    attr_reader :last_command, :last_chdir

    def initialize(output)
      @output = output
    end

    def call(command, chdir:)
      @last_command = command
      @last_chdir = chdir
      @output
    end
  end

  FakeStatus = Struct.new(:exitstatus)

  class FailingShell
    def call(*)
      raise Owlook::Sources::Queue::CommandFailedError.new(["kamal"], FakeStatus.new(1), "boom")
    end
  end
end
