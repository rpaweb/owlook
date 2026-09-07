# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::StateWriterTest < Minitest::Test
  def test_writes_the_file_when_it_does_not_exist_yet
    with_path do |path|
      wrote = Owlook::StateWriter.new(path).write([{ project: "acme" }])

      assert wrote
      assert_equal [{ "project" => "acme" }], JSON.parse(File.read(path))
    end
  end

  def test_does_not_rewrite_when_content_is_unchanged
    with_path do |path|
      writer = Owlook::StateWriter.new(path)
      writer.write([{ project: "acme" }])
      mtime_before = File.mtime(path)
      sleep 0.01

      wrote_again = writer.write([{ project: "acme" }])

      refute wrote_again
      assert_equal mtime_before, File.mtime(path)
    end
  end

  def test_rewrites_when_content_changed
    with_path do |path|
      writer = Owlook::StateWriter.new(path)
      writer.write([{ project: "acme", state: "success" }])

      wrote = writer.write([{ project: "acme", state: "failure" }])

      assert wrote
      assert_equal [{ "project" => "acme", "state" => "failure" }], JSON.parse(File.read(path))
    end
  end

  def test_leaves_no_leftover_tmp_file
    with_path do |path|
      Owlook::StateWriter.new(path).write([{ project: "acme" }])

      assert_empty Dir.glob("#{path}.tmp*")
    end
  end

  def test_writes_the_file_with_0600_not_a_world_or_group_readable_mode
    with_path do |path|
      Owlook::StateWriter.new(path).write([{ project: "acme" }])

      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_refuses_to_write_through_a_symlink_planted_at_the_target_path
    with_path do |path|
      victim = "#{path}.victim"
      File.write(victim, "untouched")
      File.symlink(victim, path)

      # A pre-existing symlink at the target path also means the
      # unchanged? check can't safely read it back (SafeFile refuses to
      # follow it) — this exercises both that fallback and the actual
      # write in one real scenario, without mocking SafeFile.
      wrote = Owlook::StateWriter.new(path).write([{ project: "acme" }])

      assert wrote
      # The rename at the end of write_atomically replaces the symlink
      # itself with the real state file — it never opens (and so never
      # writes through) the symlink's target, which is the actual attack
      # this guards against (see create_tmp_file's O_NOFOLLOW).
      refute_predicate File.lstat(path), :symlink?, "the symlink should have been replaced, not written through"
      assert_equal "untouched", File.read(victim)
    end
  end

  private

  def with_path
    Dir.mktmpdir do |dir|
      yield File.join(dir, "state.json")
    end
  end
end
