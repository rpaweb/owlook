# frozen_string_literal: true

module Owlook
  # One reported fact about a project, from one source. Two disjoint kinds,
  # not one field stretched to cover both:
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
  #                     produces these yet (Kamal hooks/SSH are out of v1
  #                     scope) — destination legitimately has no source, so
  #                     it stays absent rather than lying.
  #
  # version carries the git SHA that will eventually unify a "ci" and a
  # "deploy" row describing the same commit; timestamp is when the
  # underlying event happened (resolves conflicts); observed_at is when this
  # collector last confirmed it (the basis for "how stale is this").
  Observation = Struct.new(
    :project, :kind, :branch, :destination, :version, :state, :timestamp, :author, :source, :observed_at,
    keyword_init: true
  ) do
    def key
      case kind
      when "ci" then [project, "ci", branch]
      when "deploy" then [project, "deploy", destination]
      else raise ArgumentError, "unknown observation kind: #{kind.inspect}"
      end
    end

    def to_h
      super.transform_values { |v| v.is_a?(Time) ? v.utc.iso8601 : v }
    end
  end
end
