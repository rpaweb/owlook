# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::DeployFreshnessTest < Minitest::Test
  def test_compare_reports_zero_behind_when_the_deployed_sha_matches_the_branch_head
    with_repo do |path, shas|
      result = Owlook::DeployFreshness.new(path).compare(shas[:c3], { "main" => shas[:c3] })

      assert_equal "main", result.branch
      assert_equal 0, result.behind
    end
  end

  def test_compare_counts_commits_behind_when_the_deployed_sha_is_an_older_ancestor
    with_repo do |path, shas|
      result = Owlook::DeployFreshness.new(path).compare(shas[:c1], { "main" => shas[:c3] })

      assert_equal "main", result.branch
      assert_equal 2, result.behind
    end
  end

  def test_compare_picks_the_nearest_branch_when_the_deployed_sha_is_behind_more_than_one
    with_repo do |path, shas|
      result = Owlook::DeployFreshness.new(path).compare(
        shas[:c1], { "main" => shas[:c3], "staging" => shas[:c2] }
      )

      assert_equal "staging", result.branch
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

  private

  # Three real commits on one real branch — c1 is c3's grandparent, c2 is
  # c3's parent. shas maps each label to its real, full 40-character SHA.
  def with_repo
    Dir.mktmpdir do |dir|
      shas = {}
      Dir.chdir(dir) do
        system("git", "init", "-q", "-b", "main")
        system("git", "config", "user.email", "test@example.com")
        system("git", "config", "user.name", "Test")
        %i[c1 c2 c3].each do |label|
          File.write("file.txt", label.to_s)
          system("git", "add", "file.txt")
          system("git", "commit", "-q", "-m", label.to_s)
          shas[label] = `git rev-parse HEAD`.strip
        end
      end
      yield dir, shas
    end
  end
end
