# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::CollectorLockTest < Minitest::Test
  def test_runs_the_block_and_returns_true_when_uncontended
    with_path do |path|
      lock = Owlook::CollectorLock.new(path)
      ran = false

      result = lock.run_exclusively { ran = true }

      assert result
      assert ran
    end
  end

  # flock is tied to the open file description, not the process or the
  # path — a second File.open on the same path, in the same process, is
  # a distinct holder exactly like a second real collector process would
  # be. This is the standard way to test flock contention without
  # actually forking.
  def test_does_not_run_the_block_while_another_holder_has_the_lock
    with_path do |path|
      # Held open across the whole example on purpose, not the block
      # form — closing it is exactly what would release the lock this
      # test needs held.
      holder = File.open(path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen
      holder.flock(File::LOCK_EX)

      lock = Owlook::CollectorLock.new(path)
      ran = false

      result = lock.run_exclusively { ran = true }

      refute result
      refute ran
    ensure
      holder&.flock(File::LOCK_UN)
      holder&.close
    end
  end

  # The real scenario this exists for: two independent bin/owlook-collector
  # processes (one per monitor, see the class's own comment), not two
  # File handles in one process. Forks a real child that holds the lock
  # while the parent tries to run its own cycle — proving contention
  # actually works across process boundaries, not just within one.
  def test_a_real_second_process_holding_the_lock_blocks_this_one
    with_path do |path|
      reader, writer = IO.pipe
      child_pid = fork do
        reader.close
        child_lock = Owlook::CollectorLock.new(path)
        child_lock.run_exclusively do
          writer.write("locked")
          writer.close
          sleep 5 # held well past the parent's own attempt below
        end
      end
      writer.close
      reader.read(6) # blocks until the child actually holds the lock
      reader.close

      lock = Owlook::CollectorLock.new(path)
      ran = false

      result = lock.run_exclusively { ran = true }

      refute result
      refute ran
    ensure
      Process.kill("TERM", child_pid) if child_pid
      Process.wait(child_pid) if child_pid
    end
  end

  # The whole point of using flock over a PID/existence-based lock file:
  # nothing has to notice the holder is gone or clean anything up — the
  # kernel releases it the instant the holding process's file descriptor
  # closes, crash included (simulated here with SIGKILL, not a clean
  # exit).
  def test_the_lock_is_available_again_immediately_after_the_holder_is_killed
    with_path do |path|
      child_pid = fork do
        child_lock = Owlook::CollectorLock.new(path)
        child_lock.run_exclusively { sleep 30 }
      end
      sleep 0.2 # let the child actually acquire it first
      Process.kill("KILL", child_pid)
      Process.wait(child_pid)

      lock = Owlook::CollectorLock.new(path)
      ran = false

      result = lock.run_exclusively { ran = true }

      assert result
      assert ran
    end
  end

  # Same attack class StateWriter/GithubCache guard against — a symlink
  # planted at this exact path. There's no content to trust or distrust
  # here, only whether two instances might race one cycle, which is
  # exactly today's pre-fix behavior: proceeding without the lock is a
  # safer response than following the symlink or refusing to poll.
  def test_a_symlinked_lock_path_still_runs_the_block_instead_of_raising
    with_path do |path|
      victim = "#{path}.victim"
      File.write(victim, "untouched")
      File.symlink(victim, path)

      lock = Owlook::CollectorLock.new(path)
      ran = false

      result = lock.run_exclusively { ran = true }

      assert result
      assert ran
      assert_equal "untouched", File.read(victim)
    end
  end

  def test_creates_the_lock_file_with_0600_not_a_world_or_group_readable_mode
    with_path do |path|
      lock = Owlook::CollectorLock.new(path)

      lock.run_exclusively { nil }

      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  private

  def with_path
    Dir.mktmpdir do |dir|
      yield File.join(dir, "owlook.lock")
    end
  end
end
