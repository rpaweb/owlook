# frozen_string_literal: true

module Owlook
  # One reported fact about a project+destination's deploy state, from one
  # source. project + destination identify the row; version carries the git
  # SHA that unifies observations from different sources; timestamp is when
  # the underlying event happened (used to resolve conflicts); observed_at is
  # when this collector last confirmed it (the basis for "how stale is this").
  Observation = Struct.new(
    :project, :destination, :version, :state, :timestamp, :author, :source, :observed_at,
    keyword_init: true
  ) do
    def to_h
      super.transform_values { |v| v.is_a?(Time) ? v.utc.iso8601 : v }
    end
  end
end
