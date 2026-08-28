# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class Owlook::Sources::KamalTest < Minitest::Test
  def test_destinations_includes_default_when_the_base_file_has_servers
    with_deploy_files(
      "deploy.yml" => "service: widgets\nservers:\n  web:\n    hosts: [1.2.3.4]\n",
      "deploy.staging.yml" => "servers:\n  web:\n    hosts: [5.6.7.8]\n"
    ) do |path|
      assert_equal ["default", "staging"], Owlook::Sources::Kamal.new.destinations(path).sort
    end
  end

  # Real-world shape (confirmed against a real project): a base deploy.yml
  # with no `servers:` of its own is a shared template — registry, builder,
  # env defaults — meant to be merged with a named destination, never
  # deployed on its own. Reporting "default" for it would be a destination
  # that doesn't actually exist; nothing could ever answer for it.
  def test_destinations_excludes_default_when_the_base_file_has_no_servers
    with_deploy_files(
      "deploy.yml" => "service: widgets\nregistry:\n  server: example.com\n",
      "deploy.staging.yml" => "servers:\n  web:\n    hosts: [5.6.7.8]\n",
      "deploy.production.yml" => "servers:\n  web:\n    hosts: [9.9.9.9]\n"
    ) do |path|
      assert_equal ["production", "staging"], Owlook::Sources::Kamal.new.destinations(path).sort
    end
  end

  def test_destinations_is_empty_when_nothing_is_deployable
    with_deploy_files("deploy.yml" => "service: widgets\n") do |path|
      assert_equal [], Owlook::Sources::Kamal.new.destinations(path)
    end
  end

  def test_destinations_is_empty_without_a_deploy_yml
    Dir.mktmpdir do |path|
      assert_equal [], Owlook::Sources::Kamal.new.destinations(path)
    end
  end

  private

  def with_deploy_files(files)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      files.each { |name, content| File.write(File.join(dir, "config", name), content) }
      yield dir
    end
  end
end
