# frozen_string_literal: true

require "test_helper"

class Owlook::StoreTest < Minitest::Test
  def test_first_observation_for_a_key_is_recorded
    store = Owlook::Store.new
    changed = store.record(observation(destination: "production", timestamp: Time.at(100)))

    assert changed
    assert_equal 1, store.snapshot.size
  end

  def test_a_newer_observation_replaces_an_older_one
    store = Owlook::Store.new
    store.record(observation(destination: "production", state: "success", timestamp: Time.at(100)))
    changed = store.record(observation(destination: "production", state: "failure", timestamp: Time.at(200)))

    assert changed
    assert_equal "failure", store.snapshot.first[:state]
  end

  def test_an_older_observation_is_ignored
    store = Owlook::Store.new
    store.record(observation(destination: "production", state: "success", timestamp: Time.at(200)))
    changed = store.record(observation(destination: "production", state: "failure", timestamp: Time.at(100)))

    refute changed
    assert_equal "success", store.snapshot.first[:state]
  end

  def test_an_equally_timestamped_observation_is_ignored
    store = Owlook::Store.new
    store.record(observation(destination: "production", state: "success", timestamp: Time.at(100)))
    changed = store.record(observation(destination: "production", state: "failure", timestamp: Time.at(100)))

    refute changed
    assert_equal "success", store.snapshot.first[:state]
  end

  def test_different_destinations_are_tracked_independently
    store = Owlook::Store.new
    store.record(observation(destination: "production", timestamp: Time.at(100)))
    store.record(observation(destination: "staging", timestamp: Time.at(100)))

    assert_equal 2, store.snapshot.size
  end

  def test_different_projects_with_the_same_destination_name_are_tracked_independently
    store = Owlook::Store.new
    store.record(observation(project: "rubyevents", destination: "production", timestamp: Time.at(100)))
    store.record(observation(project: "widgets", destination: "production", timestamp: Time.at(100)))

    assert_equal 2, store.snapshot.size
  end

  def test_snapshot_entries_are_plain_hashes
    store = Owlook::Store.new
    store.record(observation(destination: "production", timestamp: Time.at(100)))

    entry = store.snapshot.first
    assert_instance_of Hash, entry
    assert_equal "acme/widgets", entry[:project]
    assert_equal "production", entry[:destination]
  end

  private

  def observation(project: "acme/widgets", destination: "production", version: "abc123",
    state: "success", timestamp: Time.now, author: "rafael", source: "github", observed_at: Time.now)
    Owlook::Observation.new(
      project: project, destination: destination, version: version, state: state,
      timestamp: timestamp, author: author, source: source, observed_at: observed_at
    )
  end
end
