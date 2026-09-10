# frozen_string_literal: true

require "test_helper"

class Owlook::RateLimitGuardTest < Minitest::Test
  def test_not_exhausted_before_any_response_has_been_seen
    guard = Owlook::RateLimitGuard.new

    refute_predicate guard, :exhausted?
  end

  def test_not_exhausted_when_remaining_is_comfortably_above_the_threshold
    guard = Owlook::RateLimitGuard.new(threshold: 200)
    guard.update(4310)

    refute_predicate guard, :exhausted?
  end

  def test_exhausted_once_remaining_drops_to_the_threshold
    guard = Owlook::RateLimitGuard.new(threshold: 200)
    guard.update(200)

    assert_predicate guard, :exhausted?
  end

  def test_exhausted_once_remaining_drops_below_the_threshold
    guard = Owlook::RateLimitGuard.new(threshold: 200)
    guard.update(5)

    assert_predicate guard, :exhausted?
  end

  # Once tripped, stays tripped for the rest of this process's life — a
  # single collector cycle shouldn't un-trip mid-cycle just because one
  # later response happened to come from a different, less-throttled
  # endpoint; the whole point is "stop spending this cycle's remaining
  # budget", not "spend right up to the edge every time".
  def test_stays_exhausted_even_if_a_later_update_reports_more_remaining
    guard = Owlook::RateLimitGuard.new(threshold: 200)
    guard.update(5)
    guard.update(4000)

    assert_predicate guard, :exhausted?
  end
end
