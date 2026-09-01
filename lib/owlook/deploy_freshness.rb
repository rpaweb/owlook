# frozen_string_literal: true

require "open3"

module Owlook
  # Compares a deployed SHA (Sources::Deploy) against every branch CI is
  # currently tracking, plus the project's own most recent git tag, using
  # the local git clone already on disk. No new user configuration, and
  # no guessing which ref a destination "belongs to" — Kamal has no
  # notion of that (config/deploy.<destination>.yml never names one), so
  # instead of assuming, this checks: is the deployed SHA a real ancestor
  # of *any* currently-tracked branch's CI-verified SHA, or of the latest
  # tag? If it's an ancestor of more than one, the nearest wins (fewest
  # commits between the two) — a production destination whose real
  # trigger is `on: push: tags: 'v*'` naturally lands on "at v1.10.2"
  # this way instead of a stale "at master", once that tag is at least
  # as close as any tracked branch (which it always is, right after a
  # release — branches keep moving, a tag never does).
  #
  # A best-effort `git fetch --tags` runs first: CI's SHA (or a brand new
  # tag) might not exist in the local clone yet if nobody's pulled since.
  # A failed fetch (offline, no remote) doesn't raise — whatever's
  # already on disk is used as-is, same as everywhere else in Owlook that
  # treats the local checkout as a real but not-guaranteed-fresh source
  # of truth.
  class DeployFreshness
    Result = Struct.new(:ref, :behind, keyword_init: true)

    def initialize(path)
      @path = path
    end

    # branch_shas: { "main" => "abc123...", "staging" => "def456..." } —
    # every branch CI currently has a real result for, same project. The
    # latest tag (if the project has any) is folded in automatically as
    # one more candidate. Returns nil when the deployed SHA isn't a real
    # ancestor of any of them — a force-push/rebase broke the
    # relationship, or the commit just isn't fetched locally — "unknown",
    # never a guessed zero.
    def compare(deployed_sha, branch_shas)
      fetch
      candidates = branch_shas.to_a
      tag = latest_tag
      candidates << tag if tag

      candidates.filter_map { |ref, sha| result_for(deployed_sha, ref, sha) }
                .min_by(&:behind)
    end

    private

    def result_for(deployed_sha, ref, sha)
      return nil unless ancestor?(deployed_sha, sha)

      count = commits_between(deployed_sha, sha)
      return nil unless count

      Result.new(ref: ref, behind: count)
    end

    # [name, sha] of the most recently created tag, or nil if the project
    # has none — only the latest, not every tag ever cut: the freshness
    # question that matters is "caught up with the current release", not
    # with some old one, and every earlier tag is by definition further
    # behind than HEAD's own branches already report.
    def latest_tag
      output, status = Open3.capture2("git", "for-each-ref", "--sort=-creatordate",
                                      "--format=%(refname:short) %(objectname)", "refs/tags", chdir: @path)
      return nil unless status.success?

      name, sha = output.lines.first&.strip&.split(" ", 2)
      return nil unless name && sha

      [name, sha]
    rescue Errno::ENOENT
      nil
    end

    def fetch
      Open3.capture2e("git", "fetch", "--quiet", "--tags", chdir: @path)
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
