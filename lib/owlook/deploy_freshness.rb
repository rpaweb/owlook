# frozen_string_literal: true

require "open3"

module Owlook
  # Compares a deployed SHA (Sources::Deploy) against every branch CI is
  # currently tracking for the same project, using the local git clone
  # already on disk. No new user configuration, and no guessing which
  # branch a destination "belongs to" — Kamal has no notion of that
  # (config/deploy.<destination>.yml never names a branch), so instead of
  # assuming, this checks: is the deployed SHA a real ancestor of *any*
  # currently-tracked branch's CI-verified SHA? If it's an ancestor of
  # more than one, the nearest wins (fewest commits between the two) —
  # the deploy reads as caught up with whichever branch it's actually
  # closest to, not an arbitrary pick.
  #
  # A best-effort `git fetch` runs first: CI's SHA might not exist in the
  # local clone yet if nobody's pulled since that run. A failed fetch
  # (offline, no remote) doesn't raise — whatever's already on disk is
  # used as-is, same as everywhere else in Owlook that treats the local
  # checkout as a real but not-guaranteed-fresh source of truth.
  class DeployFreshness
    Result = Struct.new(:branch, :behind, keyword_init: true)

    def initialize(path)
      @path = path
    end

    # branch_shas: { "main" => "abc123...", "staging" => "def456..." } —
    # every branch CI currently has a real result for, same project.
    # Returns nil when the deployed SHA isn't a real ancestor of any of
    # them — a force-push/rebase broke the relationship, or the commit
    # just isn't fetched locally — "unknown", never a guessed zero.
    def compare(deployed_sha, branch_shas)
      fetch
      branch_shas.filter_map { |branch, sha| result_for(deployed_sha, branch, sha) }
                 .min_by(&:behind)
    end

    private

    def result_for(deployed_sha, branch, sha)
      return nil unless ancestor?(deployed_sha, sha)

      count = commits_between(deployed_sha, sha)
      return nil unless count

      Result.new(branch: branch, behind: count)
    end

    def fetch
      Open3.capture2e("git", "fetch", "--quiet", chdir: @path)
    rescue Errno::ENOENT
      nil
    end

    def ancestor?(ancestor_sha, descendant_sha)
      _output, status = Open3.capture2e("git", "merge-base", "--is-ancestor", ancestor_sha, descendant_sha,
                                        chdir: @path)
      status.success?
    rescue Errno::ENOENT
      false
    end

    def commits_between(from_sha, to_sha)
      output, status = Open3.capture2("git", "rev-list", "--count", "#{from_sha}..#{to_sha}", chdir: @path)
      return nil unless status.success?

      Integer(output.strip)
    rescue Errno::ENOENT, ArgumentError
      nil
    end
  end
end
