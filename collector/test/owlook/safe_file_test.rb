# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::SafeFileTest < Minitest::Test
  def test_reads_a_real_file_this_process_owns
    with_dir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "hello")

      assert_equal "hello", Owlook::SafeFile.read(path)
    end
  end

  def test_refuses_to_follow_a_symlink
    with_dir do |dir|
      target = File.join(dir, "victim")
      File.write(target, "victim content")
      link = File.join(dir, "state.json")
      File.symlink(target, link)

      error = assert_raises(Owlook::SafeFile::UnsafeFileError) { Owlook::SafeFile.read(link) }
      assert_includes error.message, "symlink"
    end
  end

  def test_refuses_a_file_owned_by_a_different_uid
    with_dir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "hello")

      error = assert_raises(Owlook::SafeFile::UnsafeFileError) do
        Owlook::SafeFile.read(path, uid: Process.uid + 1)
      end
      assert_includes error.message, "owned by uid"
    end
  end

  def test_raises_enoent_for_a_missing_file_same_as_file_read
    with_dir do |dir|
      assert_raises(Errno::ENOENT) { Owlook::SafeFile.read(File.join(dir, "nope")) }
    end
  end

  private

  def with_dir(&)
    Dir.mktmpdir(&)
  end
end
