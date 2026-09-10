# frozen_string_literal: true

module Owlook
  # Tracks GitHub's own X-RateLimit-Remaining header across a single
  # collector cycle and trips once it gets uncomfortably low — the safety
  # net underneath GithubCache's conditional requests (a 304 costs nothing,
  # confirmed live, but a cold cache, or a burst of genuinely-changed
  # branches, can still spend real quota). Owlook sharing one token with
  # the user's own `gh` CLI and everything else that uses it means it
  # should never be the reason that quota hits zero — better to skip the
  # rest of a cycle's GitHub calls than starve every other tool on the
  # same token.
  #
  # Sticky once tripped (see #exhausted?'s own test) — this instance lives
  # for exactly one collector cycle (a fresh process every 30s), so there's
  # no "wait for the window to reset" case to handle here at all.
  class RateLimitGuard
    DEFAULT_THRESHOLD = 200

    def initialize(threshold: DEFAULT_THRESHOLD)
      @threshold = threshold
      @remaining = nil
      @exhausted = false
    end

    def update(remaining)
      @remaining = remaining
      @exhausted = true if remaining <= @threshold
    end

    def exhausted?
      @exhausted
    end
  end
end
