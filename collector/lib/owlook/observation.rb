# frozen_string_literal: true

module Owlook
  # One reported fact about a project, from one source. Five disjoint kinds,
  # not one field stretched to cover all of them:
  #
  #   kind: "ci"     - identified by project + branch. What GitHub Actions
  #                     reports. destination is always nil here — CI has no
  #                     concept of a deploy destination, and faking one
  #                     (e.g. from the branch name) breaks dedup: two
  #                     branches would never reconcile with a real deploy
  #                     observation for the same destination, and checking
  #                     out a feature branch would silently stop reporting
  #                     production's status.
  #   kind: "deploy"  - identified by project + destination. Produced by
  #                     Sources::Deploy (`kamal app version`). `details`
  #                     carries the freshness comparison against CI-verified
  #                     branch SHAs and the repo's own latest git tag (see
  #                     DeployFreshness) — `fresh_ref`/`behind`, absent when
  #                     no branch or tag matches.
  #   kind: "queue"   - identified by project + destination, same as
  #                     "deploy": a queue backlog belongs to a deployed
  #                     environment, not a branch. Produced by
  #                     Sources::Queue. Backlog/dead-job counts live in
  #                     `details` rather than as top-level fields, since
  #                     they only make sense for this one kind.
  #   kind: "ci_timing" / "queue_timing" - identified by project alone (one
  #                     row per project, not per branch/destination): how
  #                     long that project's most recent CI/queue poll cycle
  #                     actually took, in `details[:duration_seconds]`. Not
  #                     a check result — Model.js's isRealCheck excludes
  #                     both from "N check(s) passing" the same way it
  #                     excludes "no_runs"/"checking".
  #
  # version carries the git SHA that unifies a "ci" and a "deploy" row
  # describing the same commit (nil for "queue", which has no version
  # concept); timestamp is when the underlying event happened
  # (resolves conflicts); observed_at is when this collector last confirmed
  # it (the basis for "how stale is this").
  Observation = Struct.new(
    :project, :kind, :branch, :destination, :version, :state, :details,
    :timestamp, :author, :source, :observed_at,
    keyword_init: true
  ) do
    # Kept in sync by hand with Model.js's own BAD_STATES — the widget
    # decides what reads as "bad" for coloring, Collector decides the same
    # thing for whether a state change is worth a desktop notification
    # (see Collector#notify_on_transition). Same vocabulary, different
    # language, no shared source of truth across the process boundary.
    # rubocop:disable Lint/ConstantDefinitionInBlock -- attaching a constant
    # to a Struct's own block is the point here, not an accident of scope.
    BAD_STATES = %w[failure timed_out action_required cancelled startup_failure failing unreachable].freeze
    # rubocop:enable Lint/ConstantDefinitionInBlock

    def self.bad_state?(state)
      BAD_STATES.include?(state)
    end

    def initialize(**kwargs)
      super(details: {}, **kwargs)
    end

    def key
      case kind
      when "ci" then [project, "ci", branch]
      when "deploy" then [project, "deploy", destination]
      when "queue" then [project, "queue", destination]
      when "ci_timing" then [project, "ci_timing"]
      when "queue_timing" then [project, "queue_timing"]
      else raise ArgumentError, "unknown observation kind: #{kind.inspect}"
      end
    end

    def to_h
      super.transform_values { |v| v.is_a?(Time) ? v.utc.iso8601 : v }
    end
  end
end
