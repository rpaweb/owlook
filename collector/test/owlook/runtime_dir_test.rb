# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::RuntimeDirTest < Minitest::Test
  def test_uses_xdg_runtime_dir_when_set_and_already_safe
    with_dir do |dir|
      File.chmod(0o700, dir)

      resolved = Owlook::RuntimeDir.resolve(env: { "XDG_RUNTIME_DIR" => dir })

      assert_equal dir, resolved
    end
  end

  def test_creates_the_directory_with_0700_when_it_does_not_exist_yet
    with_dir do |dir|
      target = File.join(dir, "owlook-runtime")

      resolved = Owlook::RuntimeDir.resolve(env: { "XDG_RUNTIME_DIR" => target })

      assert_equal target, resolved
      assert_equal 0o700, File.stat(target).mode & 0o777
    end
  end

  def test_tightens_an_over_permissive_mode_on_a_directory_it_owns
    with_dir do |dir|
      File.chmod(0o755, dir)

      Owlook::RuntimeDir.resolve(env: { "XDG_RUNTIME_DIR" => dir })

      assert_equal 0o700, File.stat(dir).mode & 0o777
    end
  end

  def test_refuses_a_symlinked_runtime_dir
    with_dir do |dir|
      real_dir = File.join(dir, "real")
      Dir.mkdir(real_dir, 0o700)
      link = File.join(dir, "link")
      File.symlink(real_dir, link)

      error = assert_raises(Owlook::RuntimeDir::UnsafeDirectoryError) do
        Owlook::RuntimeDir.resolve(env: { "XDG_RUNTIME_DIR" => link })
      end
      assert_includes error.message, "symlink"
    end
  end

  def test_refuses_a_directory_owned_by_a_different_uid
    with_dir do |dir|
      File.chmod(0o700, dir)

      error = assert_raises(Owlook::RuntimeDir::UnsafeDirectoryError) do
        Owlook::RuntimeDir.resolve(env: { "XDG_RUNTIME_DIR" => dir }, uid: Process.uid + 1)
      end
      assert_includes error.message, "owned by uid"
    end
  end

  def test_falls_back_to_a_per_user_cache_dir_when_xdg_runtime_dir_is_unset
    with_dir do |home|
      resolved = Owlook::RuntimeDir.resolve(env: { "HOME" => home })

      assert_equal File.join(home, ".cache", "owlook"), resolved
      assert_equal 0o700, File.stat(resolved).mode & 0o777
    end
  end

  private

  def with_dir(&)
    Dir.mktmpdir(&)
  end
end
