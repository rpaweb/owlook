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
          - #{dir}/rubyevents
          - ~/Work/oss/other-project
      YAML

      config = Owlook::Config.load(path)

      assert_equal [
        File.join(dir, "rubyevents"),
        File.expand_path("~/Work/oss/other-project")
      ], config.projects
    end
  end

  def test_missing_file_raises_a_clear_error
    error = assert_raises(Owlook::Config::MissingFileError) do
      Owlook::Config.load("/nonexistent/owlook/config.yml")
    end

    assert_includes error.message, "/nonexistent/owlook/config.yml"
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
