# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::DeployFreshnessTest < Minitest::Test
  def test_compare_reports_zero_behind_when_the_deployed_sha_matches_the_branch_head
    with_repo do |path, shas|
      result = Owlook::DeployFreshness.new(path).compare(shas[:c3], { "main" => shas[:c3] })

      assert_equal "main", result.ref
      assert_equal 0, result.behind
    end
  end

  def test_compare_counts_commits_behind_when_the_deployed_sha_is_an_older_ancestor
    with_repo do |path, shas|
      result = Owlook::DeployFreshness.new(path).compare(shas[:c1], { "main" => shas[:c3] })

      assert_equal "main", result.ref
      assert_equal 2, result.behind
    end
  end

  def test_compare_picks_the_nearest_branch_when_the_deployed_sha_is_behind_more_than_one
    with_repo do |path, shas|
      result = Owlook::DeployFreshness.new(path).compare(
        shas[:c1], { "main" => shas[:c3], "staging" => shas[:c2] }
      )

      assert_equal "staging", result.ref
      assert_equal 1, result.behind
    end
  end

  # A force-push/rebase (or just a SHA that was never real) breaks the
  # ancestor relationship entirely — "unknown", not a guessed zero.
  def test_compare_returns_nil_when_the_deployed_sha_is_not_an_ancestor_of_any_tracked_branch
    with_repo do |path, shas|
      result = Owlook::DeployFreshness.new(path).compare(shas[:c1], { "main" => "0" * 40 })

      assert_nil result
    end
  end

  def test_compare_returns_nil_when_given_no_branches_at_all
    with_repo do |path, shas|
      result = Owlook::DeployFreshness.new(path).compare(shas[:c1], {})

      assert_nil result
    end
  end

  # Real scenario: a production destination whose actual deploy trigger
  # is `on: push: tags: 'v*'`, not a branch — main has moved on since the
  # release, so the tag (0 behind) is the nearer match and wins over it.
  def test_compare_prefers_the_latest_tag_over_a_branch_when_the_tag_is_the_closer_match
    with_repo do |path, shas|
      tag(path, "v1.0.0", shas[:c2])

      result = Owlook::DeployFreshness.new(path).compare(shas[:c2], { "main" => shas[:c3] })

      assert_equal "v1.0.0", result.ref
      assert_equal 0, result.behind
    end
  end

  def test_compare_matches_the_latest_tag_even_with_no_tracked_branches_at_all
    with_repo do |path, shas|
      tag(path, "v1.0.0", shas[:c2])

      result = Owlook::DeployFreshness.new(path).compare(shas[:c2], {})

      assert_equal "v1.0.0", result.ref
      assert_equal 0, result.behind
    end
  end

  # Only the most recent tag is a candidate — an older tag existing too
  # shouldn't win just because it happens to also be an ancestor. A
  # lightweight tag (what `git tag <name> <sha>` makes, and what real
  # GitHub-created release tags turn out to be too — confirmed live
  # against Luxtown's own v1.10.2) has no creation timestamp of its own;
  # `--sort=-creatordate` falls back to the underlying commit's date, so
  # this only sorts correctly because with_repo gives c1/c2/c3 real,
  # distinct dates a day apart — not because of anything about *when*
  # the `tag` calls below happen to run.
  def test_compare_only_considers_the_most_recently_created_tag
    with_repo do |path, shas|
      tag(path, "v1.0.0", shas[:c1])
      tag(path, "v2.0.0", shas[:c3])

      result = Owlook::DeployFreshness.new(path).compare(shas[:c3], {})

      assert_equal "v2.0.0", result.ref
      assert_equal 0, result.behind
    end
  end

  private

  def tag(path, name, sha)
    Dir.chdir(path) { system("git", "tag", name, sha) }
  end

  # Three real commits on one real branch, a day apart — c1 is c3's
  # grandparent, c2 is c3's parent. shas maps each label to its real,
  # full 40-character SHA. Explicit dates (not just commit order) matter
  # for the latest-tag tests above: a lightweight tag's own sort date is
  # its commit's date, and commits made back-to-back in a fast test run
  # can otherwise land in the same second.
  def with_repo
    Dir.mktmpdir do |dir|
      shas = {}
      Dir.chdir(dir) do
        system("git", "init", "-q", "-b", "main")
        system("git", "config", "user.email", "test@example.com")
        system("git", "config", "user.name", "Test")
        commits = {
          c1: "2024-01-01T00:00:00",
          c2: "2024-01-02T00:00:00",
          c3: "2024-01-03T00:00:00"
        }
        commits.each do |label, date|
          File.write("file.txt", label.to_s)
          system("git", "add", "file.txt")
          system({ "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date },
                 "git", "commit", "-q", "-m", label.to_s)
          shas[label] = `git rev-parse HEAD`.strip
        end
      end
      yield dir, shas
    end
  end
end
