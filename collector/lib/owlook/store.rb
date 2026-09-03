# frozen_string_literal: true

require "json"
require "time"

module Owlook
  # In-memory merge of Observations into one row per project+destination.
  # Conflicts resolve by timestamp: whichever observation describes the more
  # recent event wins, regardless of which source reported it or when it was
  # observed. Purely in-memory — persistence is StateWriter's job.
  class Store
    # Rehydrates a Store from a previously-written state file — what makes
    # a single-shot collector process (invoked fresh every cycle by the
    # widget's own Timer, not a long-lived daemon) behave the same as one
    # that's been running the whole time. Without this, every branch and
    # destination would look brand new on every single invocation: the
    # "checking" placeholder dance (see Collector#announce_new_ci_branches)
    # exists specifically for a genuinely new branch, and firing it every
    # cycle would flash real data back to "checking" constantly instead of
    # just once, ever, per branch/destination. Missing or unparseable file
    # (first run, corrupt write) is the same as no prior state — not an
    # error, same as StateWriter treating a missing file as "nothing
    # written yet".
    def self.load(path)
      store = new
      raw = JSON.parse(File.read(path), symbolize_names: true)
      raw.each do |entry|
        entry[:timestamp] = Time.parse(entry[:timestamp]) if entry[:timestamp]
        entry[:observed_at] = Time.parse(entry[:observed_at]) if entry[:observed_at]
        store.record(Observation.new(**entry))
      end
      store
    rescue Errno::ENOENT, JSON::ParserError
      store
    end

    def initialize
      @entries = {}
    end

    # Returns true if this observation changed the stored state for its key,
    # false if it was a no-op (older, equal, or duplicate). The key itself
    # is the observation's business (see Observation#key) — a "ci" row and a
    # "deploy" row for the same project never collide.
    def record(observation)
      key = observation.key
      current = @entries[key]
      return false if current && current.timestamp >= observation.timestamp

      @entries[key] = observation
      true
    end

    def known?(key)
      @entries.key?(key)
    end

    # The Observation currently stored for a key, or nil — a read before
    # #record's write, so a caller can compare what a new observation is
    # about to replace (see Collector#notify_on_transition, which needs
    # the previous state to know whether this is an actual change worth a
    # desktop notification).
    def current(key)
      @entries[key]
    end

    # Every stored observation of one kind for one project — the query
    # #current can't answer, since that needs an exact key up front and
    # this needs "every branch CI has a result for right now" without
    # knowing in advance what those branches are (see
    # Collector#deploy_freshness_details, the one caller).
    def entries_for(project:, kind:)
      @entries.select { |key, _observation| key[0] == project && key[1] == kind }.values
    end

    # Removes a project's stored "ci" observations for any branch not in
    # keep_branches. Normal polling only ever adds or replaces, never
    # deletes — this is the one exception, called every cycle (see
    # Collector#poll_project_ci) with whatever branch list this cycle
    # actually computed, so a branch no longer relevant — the "all
    # branches" setting flipped back off, or the branch was simply merged
    # or deleted upstream — doesn't sit in the state file forever with
    # nothing else to prune it. Unconditional rather than gated on
    # detecting a settings change: a single-shot process re-launched fresh
    # every cycle (see bin/owlook-collector) has no reliable way to tell
    # "the setting just changed" apart from "this happens to be this
    # process's first poll" — an earlier version of this reconciliation
    # lived in Collector as a transition check against an in-memory
    # @known_all_branches, which broke silently under exactly that
    # architecture (every cycle looked like a first poll, so it never
    # fired) without failing any existing test, since those tests reused
    # one Collector across multiple polls instead of a fresh one per
    # cycle.
    def forget_ci_branches(project, keep_branches)
      @entries.reject! { |key, _observation| key[0] == project && key[1] == "ci" && !keep_branches.include?(key[2]) }
    end

    # Removes every stored observation — any kind, any branch/destination —
    # for a project not in keep_projects. A project removed from
    # config.yml stops being polled entirely, but nothing else ever
    # removes what's already in the Store: without this, a project you
    # deleted from config.yml keeps showing its last-known tab, CI, and
    # queue rows forever, since the state file only ever gets added to or
    # replaced, never reconciled against what's actually still configured.
    # See Collector#poll_ci_once, the one caller — every kind lives under
    # one project identifier (key[0], "owner/repo"), so one pass here
    # covers CI, deploy, queue, and both *_timing kinds at once.
    def forget_projects_except(keep_projects)
      @entries.select! { |key, _observation| keep_projects.include?(key[0]) }
    end

    def snapshot
      @entries.values.map(&:to_h)
    end
  end
end
