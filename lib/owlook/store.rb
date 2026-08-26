# frozen_string_literal: true

module Owlook
  # In-memory merge of Observations into one row per project+destination.
  # Conflicts resolve by timestamp: whichever observation describes the more
  # recent event wins, regardless of which source reported it or when it was
  # observed. Purely in-memory — persistence is StateWriter's job.
  class Store
    def initialize
      @entries = {}
    end

    # Returns true if this observation changed the stored state for its key,
    # false if it was a no-op (older, equal, or duplicate).
    def record(observation)
      key = [observation.project, observation.destination]
      current = @entries[key]
      return false if current && current.timestamp >= observation.timestamp

      @entries[key] = observation
      true
    end

    def snapshot
      @entries.values.map(&:to_h)
    end
  end
end
