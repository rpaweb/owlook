# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class Owlook::ConfigTest < Minitest::Test
  def test_projects_returns_expanded_paths_listed_in_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        projects:
          - #{dir}/exampleapp
          - ~/Work/oss/other-project
      YAML

      config = Owlook::Config.load(path)

      assert_equal [
        File.join(dir, "exampleapp"),
        File.expand_path("~/Work/oss/other-project")
      ], config.projects
    end
  end

  # Real user report: installed the plugin with no config.yml yet (an
  # entirely ordinary first run) and got no guidance on what to put in
  # it — the collector used to raise here instead of writing something
  # helpful. Also confirms the parent directory gets created too, since
  # a fresh install has neither ~/.config/owlook/ nor the file itself.
  def test_missing_file_gets_created_with_a_commented_template_and_zero_projects
    Dir.mktmpdir do |dir|
      path = File.join(dir, "owlook", "config.yml")

      config = Owlook::Config.load(path)

      assert_equal [], config.projects
      assert_path_exists path
      written = File.read(path)

      assert_includes written, "projects:"
      assert_includes written, "~/Work/oss/exampleapp"
    end
  end

  def test_loading_twice_does_not_overwrite_a_file_the_user_already_edited
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")

      Owlook::Config.load(path) # first run: writes the template
      File.write(path, "projects:\n  - #{dir}/realapp\n") # user edits it for real

      config = Owlook::Config.load(path)

      assert_equal [File.join(dir, "realapp")], config.projects
    end
  end

  def test_empty_file_has_no_projects
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "")

      config = Owlook::Config.load(path)

      assert_equal [], config.projects
    end
  end

  def test_invalid_yaml_raises_a_clear_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "projects: [unterminated")

      error = assert_raises(Owlook::Config::InvalidFileError) do
        Owlook::Config.load(path)
      end

      assert_includes error.message, path
    end
  end
end
