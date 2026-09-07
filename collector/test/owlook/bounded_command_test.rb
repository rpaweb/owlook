# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "timeout"

class Owlook::BoundedCommandTest < Minitest::Test
  def test_captures_stdout_stderr_and_status_from_a_real_process
    result = Owlook::BoundedCommand.run(
      "sh", "-c", "echo out; echo err 1>&2; exit 3", chdir: Dir.pwd
    )

    assert_equal "out\n", result.stdout
    assert_equal "err\n", result.stderr
    assert_equal 3, result.status.exitstatus
  end

  def test_raises_timeout_error_and_actually_kills_the_hung_process
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "child.pid")

      assert_raises(Owlook::BoundedCommand::TimeoutError) do
        Owlook::BoundedCommand.run("sh", "-c", "echo $$ > #{marker}; sleep 30", chdir: dir, timeout: 0.3)
      end

      child_pid = Integer(File.read(marker).strip)

      refute process_alive?(child_pid), "child #{child_pid} survived the timeout kill"
    end
  end

  def test_kills_the_whole_process_group_not_just_the_direct_child
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "grandchild.pid")
      # The direct child is `sh`, which forks a grandchild `sleep` into
      # the background and exits immediately itself — if only the
      # direct pid were killed, the grandchild (still alive, sharing
      # the same pgroup) would survive as an orphan.
      script = "sh -c 'sleep 30 & echo $! > #{marker}'"

      assert_raises(Owlook::BoundedCommand::TimeoutError) do
        Owlook::BoundedCommand.run("sh", "-c", script, chdir: dir, timeout: 0.3)
      end

      Timeout.timeout(2) { sleep 0.05 until File.exist?(marker) }
      grandchild_pid = Integer(File.read(marker).strip)
      sleep 0.3 # let the kill signal actually land

      refute process_alive?(grandchild_pid), "grandchild #{grandchild_pid} survived the timeout kill"
    end
  end

  def test_raises_output_too_large_error_instead_of_buffering_forever
    assert_raises(Owlook::BoundedCommand::OutputTooLargeError) do
      Owlook::BoundedCommand.run(
        "sh", "-c", "yes | head -c 100000", chdir: Dir.pwd, max_bytes: 1_000
      )
    end
  end

  private

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
