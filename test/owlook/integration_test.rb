# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Proves the plumbing Hito 3 promises: observations -> Store -> StateWriter
# -> JSON file, deduplicated and written atomically only on real change.
# Deliberately source-agnostic — how a real source's payload becomes an
# Observation is Hito 4's job (it needs the branch->destination mapping
# question answered first, which is still open).
class Owlook::IntegrationTest < Minitest::Test
  def test_recorded_observations_land_in_the_state_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      store = Owlook::Store.new
      writer = Owlook::StateWriter.new(path)

      store.record(Owlook::Observation.new(
        project: "acme/widgets", destination: "production", version: "abc123",
        state: "success", timestamp: Time.at(100), author: "rafael",
        source: "github", observed_at: Time.at(150)
      ))
      writer.write(store.snapshot)

      on_disk = JSON.parse(File.read(path))
      assert_equal 1, on_disk.size
      assert_equal "acme/widgets", on_disk.first["project"]
      assert_equal "success", on_disk.first["state"]
    end
  end

  def test_a_second_poll_with_no_new_data_does_not_touch_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      store = Owlook::Store.new
      writer = Owlook::StateWriter.new(path)
      observation = Owlook::Observation.new(
        project: "acme/widgets", destination: "production", version: "abc123",
        state: "success", timestamp: Time.at(100), author: "rafael",
        source: "github", observed_at: Time.at(150)
      )

      store.record(observation)
      writer.write(store.snapshot)
      mtime_after_first_write = File.mtime(path)
      sleep 0.01

      # Same poll result arrives again (e.g. GitHub returns the same run).
      store.record(observation)
      writer.write(store.snapshot)

      assert_equal mtime_after_first_write, File.mtime(path)
    end
  end

  def test_a_newer_observation_from_a_different_source_overwrites_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      store = Owlook::Store.new
      writer = Owlook::StateWriter.new(path)

      store.record(Owlook::Observation.new(
        project: "acme/widgets", destination: "production", version: "abc123",
        state: "running", timestamp: Time.at(100), author: "rafael",
        source: "github", observed_at: Time.at(150)
      ))
      writer.write(store.snapshot)

      store.record(Owlook::Observation.new(
        project: "acme/widgets", destination: "production", version: "abc123",
        state: "success", timestamp: Time.at(200), author: "rafael",
        source: "kamal-hook", observed_at: Time.at(250)
      ))
      writer.write(store.snapshot)

      on_disk = JSON.parse(File.read(path))
      assert_equal "success", on_disk.first["state"]
      assert_equal "kamal-hook", on_disk.first["source"]
    end
  end
end
