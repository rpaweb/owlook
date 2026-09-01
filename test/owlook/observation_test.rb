# frozen_string_literal: true

require "test_helper"

class Owlook::ObservationTest < Minitest::Test
  def test_key_for_a_ci_observation_is_project_and_branch
    observation = Owlook::Observation.new(
      project: "acme/widgets", kind: "ci", branch: "main", destination: nil,
      version: "abc123", state: "success", timestamp: Time.now,
      author: "rafael", source: "github", observed_at: Time.now
    )

    assert_equal ["acme/widgets", "ci", "main"], observation.key
  end

  def test_key_for_a_deploy_observation_is_project_and_destination
    observation = Owlook::Observation.new(
      project: "acme/widgets", kind: "deploy", branch: nil, destination: "production",
      version: "abc123", state: "success", timestamp: Time.now,
      author: "rafael", source: "kamal-hook", observed_at: Time.now
    )

    assert_equal ["acme/widgets", "deploy", "production"], observation.key
  end

  def test_key_for_a_queue_observation_is_project_and_destination
    observation = Owlook::Observation.new(
      project: "acme/widgets", kind: "queue", branch: nil, destination: "production",
      version: nil, state: "ok", details: { ready: 3, failed: 0 }, timestamp: Time.now,
      author: nil, source: "kamal-exec", observed_at: Time.now
    )

    assert_equal ["acme/widgets", "queue", "production"], observation.key
  end

  def test_key_for_a_ci_timing_observation_is_project_alone
    observation = Owlook::Observation.new(
      project: "acme/widgets", kind: "ci_timing", branch: nil, destination: nil,
      version: nil, state: "ok", details: { duration_seconds: 0.9 }, timestamp: Time.now,
      author: nil, source: "github", observed_at: Time.now
    )

    assert_equal ["acme/widgets", "ci_timing"], observation.key
  end

  def test_key_for_a_queue_timing_observation_is_project_alone
    observation = Owlook::Observation.new(
      project: "acme/widgets", kind: "queue_timing", branch: nil, destination: nil,
      version: nil, state: "ok", details: { duration_seconds: 22.4 }, timestamp: Time.now,
      author: nil, source: "kamal-exec", observed_at: Time.now
    )

    assert_equal ["acme/widgets", "queue_timing"], observation.key
  end

  def test_key_raises_for_an_unknown_kind
    observation = Owlook::Observation.new(
      project: "acme/widgets", kind: "bogus", branch: "main", destination: nil,
      version: "abc123", state: "success", timestamp: Time.now,
      author: "rafael", source: "github", observed_at: Time.now
    )

    assert_raises(ArgumentError) { observation.key }
  end

  def test_bad_state_is_true_for_every_known_bad_state
    %w[failure timed_out action_required cancelled startup_failure failing unreachable].each do |state|
      assert Owlook::Observation.bad_state?(state), "expected #{state.inspect} to be bad"
    end
  end

  # startup_failure is a real GitHub Actions conclusion (a workflow that
  # can't even start, most often a bad workflow file) caught live: it
  # fell through as neither good nor bad, so a transition into it never
  # fired a desktop notification. neutral/skipped/stale are real
  # conclusion values too, deliberately not bad — none of them mean the
  # code is broken.
  def test_bad_state_is_false_for_a_good_or_neutral_state
    %w[success ok in_progress queued no_runs checking neutral skipped stale].each do |state|
      refute Owlook::Observation.bad_state?(state), "expected #{state.inspect} not to be bad"
    end
  end

  def test_to_h_formats_times_as_iso8601
    time = Time.at(1_756_224_000) # fixed instant, no local-tz ambiguity
    observation = Owlook::Observation.new(
      project: "acme/widgets", kind: "ci", branch: "main", destination: nil,
      version: "abc123", state: "success", timestamp: time,
      author: "rafael", source: "github", observed_at: time
    )

    hash = observation.to_h

    assert_equal time.utc.iso8601, hash[:timestamp]
    assert_equal time.utc.iso8601, hash[:observed_at]
  end
end
