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

      refute File.exist?("#{path}.tmp")
    end
  end

  private

  def with_path
    Dir.mktmpdir do |dir|
      yield File.join(dir, "state.json")
    end
  end
end
