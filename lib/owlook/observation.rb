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
  #   kind: "deploy"  - identified by project + destination. Nothing
  #                     produces these yet (Kamal hooks/SSH reconciliation
  #                     are out of v1 scope) — destination legitimately has
  #                     no source, so it stays absent rather than lying.
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
  # version carries the git SHA that will eventually unify a "ci" and a
  # "deploy" row describing the same commit (nil for "queue", which has no
  # version concept); timestamp is when the underlying event happened
  # (resolves conflicts); observed_at is when this collector last confirmed
  # it (the basis for "how stale is this").
  Observation = Struct.new(
    :project, :kind, :branch, :destination, :version, :state, :details,
    :timestamp, :author, :source, :observed_at,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      super(**{ details: {} }.merge(kwargs))
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
