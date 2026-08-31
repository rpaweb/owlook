# frozen_string_literal: true

require "test_helper"

class Owlook::StoreTest < Minitest::Test
  def test_first_observation_for_a_key_is_recorded
    store = Owlook::Store.new
    changed = store.record(ci_observation(branch: "main", timestamp: Time.at(100)))

    assert changed
    assert_equal 1, store.snapshot.size
  end

  def test_a_newer_observation_replaces_an_older_one
    store = Owlook::Store.new
    store.record(ci_observation(branch: "main", state: "success", timestamp: Time.at(100)))
    changed = store.record(ci_observation(branch: "main", state: "failure", timestamp: Time.at(200)))

    assert changed
    assert_equal "failure", store.snapshot.first[:state]
  end

  def test_an_older_observation_is_ignored
    store = Owlook::Store.new
    store.record(ci_observation(branch: "main", state: "success", timestamp: Time.at(200)))
    changed = store.record(ci_observation(branch: "main", state: "failure", timestamp: Time.at(100)))

    refute changed
    assert_equal "success", store.snapshot.first[:state]
  end

  def test_an_equally_timestamped_observation_is_ignored
    store = Owlook::Store.new
    store.record(ci_observation(branch: "main", state: "success", timestamp: Time.at(100)))
    changed = store.record(ci_observation(branch: "main", state: "failure", timestamp: Time.at(100)))

    refute changed
    assert_equal "success", store.snapshot.first[:state]
  end

  def test_different_branches_are_tracked_independently
    store = Owlook::Store.new
    store.record(ci_observation(branch: "main", timestamp: Time.at(100)))
    store.record(ci_observation(branch: "feature-x", timestamp: Time.at(100)))

    assert_equal 2, store.snapshot.size
  end

  def test_different_projects_with_the_same_branch_name_are_tracked_independently
    store = Owlook::Store.new
    store.record(ci_observation(project: "exampleapp", branch: "main", timestamp: Time.at(100)))
    store.record(ci_observation(project: "widgets", branch: "main", timestamp: Time.at(100)))

    assert_equal 2, store.snapshot.size
  end

  def test_a_ci_row_and_a_deploy_row_for_the_same_project_never_collide
    store = Owlook::Store.new
    store.record(ci_observation(project: "acme/widgets", branch: "main", timestamp: Time.at(100)))
    store.record(deploy_observation(project: "acme/widgets", destination: "production", timestamp: Time.at(100)))

    assert_equal 2, store.snapshot.size
  end

  def test_known_is_false_before_anything_is_recorded_for_a_key
    store = Owlook::Store.new

    refute store.known?(ci_observation(branch: "main").key)
  end

  def test_known_is_true_once_something_is_recorded_for_a_key
    store = Owlook::Store.new
    observation = ci_observation(branch: "main")
    store.record(observation)

    assert store.known?(observation.key)
  end

  def test_forget_kind_removes_only_observations_of_that_kind
    store = Owlook::Store.new
    store.record(ci_observation(branch: "main", timestamp: Time.at(100)))
    store.record(ci_observation(branch: "staging", timestamp: Time.at(100)))
    store.record(deploy_observation(destination: "production", timestamp: Time.at(100)))

    store.forget_kind("ci")

    kinds = store.snapshot.map { |e| e[:kind] }

    assert_equal ["deploy"], kinds
  end

  def test_forget_kind_is_a_no_op_when_nothing_of_that_kind_exists
    store = Owlook::Store.new
    store.record(deploy_observation(destination: "production", timestamp: Time.at(100)))

    store.forget_kind("ci")

    assert_equal 1, store.snapshot.size
  end

  def test_snapshot_entries_are_plain_hashes
    store = Owlook::Store.new
    store.record(ci_observation(branch: "main", timestamp: Time.at(100)))

    entry = store.snapshot.first

    assert_instance_of Hash, entry
    assert_equal "acme/widgets", entry[:project]
    assert_equal "main", entry[:branch]
    assert_nil entry[:destination]
  end

  private

  def ci_observation(project: "acme/widgets", branch: "main", version: "abc123",
                     state: "success", timestamp: Time.now, author: "rafael", source: "github", observed_at: Time.now)
    Owlook::Observation.new(
      project: project, kind: "ci", branch: branch, destination: nil, version: version, state: state,
      timestamp: timestamp, author: author, source: source, observed_at: observed_at
    )
  end

  def deploy_observation(project: "acme/widgets", destination: "production", version: "abc123",
                         state: "success", timestamp: Time.now, author: "rafael", source: "kamal-hook", observed_at: Time.now)
    Owlook::Observation.new(
      project: project, kind: "deploy", branch: nil, destination: destination, version: version, state: state,
      timestamp: timestamp, author: author, source: source, observed_at: observed_at
    )
  end
end
