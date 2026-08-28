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
    error = Owlook::Sources::Queue::CommandFailedError.new(["kamal", "app", "exec"], FakeStatus.new(1), "No container found")

    assert_includes error.message, "No container found"
  end

  private

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
