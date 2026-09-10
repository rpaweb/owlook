# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::GithubCacheTest < Minitest::Test
  def test_returns_nil_for_a_url_never_stored
    with_path do |path|
      cache = Owlook::GithubCache.new(path)

      assert_nil cache.etag_for("https://api.github.com/repos/acme/widgets/actions/runs")
      assert_nil cache.body_for("https://api.github.com/repos/acme/widgets/actions/runs")
    end
  end

  def test_stores_and_retrieves_etag_and_body_for_a_url
    with_path do |path|
      cache = Owlook::GithubCache.new(path)
      url = "https://api.github.com/repos/acme/widgets/actions/runs"

      cache.store(url, etag: '"abc123"', body: '{"workflow_runs":[]}')

      assert_equal '"abc123"', cache.etag_for(url)
      assert_equal '{"workflow_runs":[]}', cache.body_for(url)
    end
  end

  # The collector is a fresh process every 30s (see bin/owlook-collector) —
  # an in-memory cache would be empty every single cycle and never save a
  # single request. This is the whole point of persisting it: a *second*
  # Owlook::GithubCache instance, loaded from the same path, has to see
  # what the first one stored.
  def test_persists_across_separate_instances_via_save_and_reload
    with_path do |path|
      url = "https://api.github.com/repos/acme/widgets/actions/runs"
      first = Owlook::GithubCache.new(path)
      first.store(url, etag: '"abc123"', body: '{"workflow_runs":[]}')
      first.save

      second = Owlook::GithubCache.new(path)

      assert_equal '"abc123"', second.etag_for(url)
      assert_equal '{"workflow_runs":[]}', second.body_for(url)
    end
  end

  def test_a_missing_file_starts_empty_instead_of_raising
    with_path do |path|
      cache = Owlook::GithubCache.new(File.join(path, "nonexistent.json"))

      assert_nil cache.etag_for("https://example.com")
    end
  end

  def test_a_corrupt_file_starts_empty_instead_of_raising
    with_path do |path|
      File.write(path, "not json")
      cache = Owlook::GithubCache.new(path)

      assert_nil cache.etag_for("https://example.com")
    end
  end

  # Syntactically valid JSON, wrong shape — disk corruption, a manual
  # edit, or a future incompatible format could all produce this.
  # JSON::ParserError never catches it (it parses cleanly), so every
  # entries.dig/[]= call downstream would raise on a non-Hash unless
  # this is checked explicitly. Confirmed live before this fix: a literal
  # "null" file broke etag_for and store both.
  def test_a_file_containing_valid_json_that_is_not_a_hash_starts_empty
    with_path do |path|
      File.write(path, "null")
      cache = Owlook::GithubCache.new(path)

      assert_nil cache.etag_for("https://example.com")
      cache.store("https://example.com", etag: '"abc123"', body: "{}")

      assert_equal '"abc123"', cache.etag_for("https://example.com")
    end
  end

  def test_an_array_shaped_json_file_also_starts_empty
    with_path do |path|
      File.write(path, "[]")
      cache = Owlook::GithubCache.new(path)

      assert_nil cache.etag_for("https://example.com")
    end
  end

  # The real scenario this exists for: a branch gets merged/closed and
  # simply stops appearing in branches_with_runs — nothing ever tells
  # this class its URL is gone. Without expiry, "all branches" on a repo
  # with real dependabot/renovate churn (this PR's own motivating case)
  # accumulates permanent garbage entries.
  def test_save_prunes_entries_older_than_the_retention_window
    with_path do |path|
      stale_url = "https://api.github.com/repos/acme/widgets/actions/runs?branch=long-merged"
      fresh_url = "https://api.github.com/repos/acme/widgets/actions/runs?branch=master"
      raw = {
        stale_url => { "etag" => '"old"', "body" => "{}", "stored_at" => Time.now.to_i - (Owlook::GithubCache::RETENTION + 1) },
        fresh_url => { "etag" => '"new"', "body" => "{}", "stored_at" => Time.now.to_i }
      }
      File.write(path, JSON.generate(raw))

      cache = Owlook::GithubCache.new(path)
      cache.save
      reloaded = Owlook::GithubCache.new(path)

      assert_nil reloaded.etag_for(stale_url)
      assert_equal '"new"', reloaded.etag_for(fresh_url)
    end
  end

  # Same real attack StateWriter's own test guards against: another local
  # user pre-plants a symlink at this exact path, hoping our write follows
  # it into a file *they* chose. #save must replace the symlink itself
  # (what File.rename does), never open and write through it.
  def test_save_refuses_to_write_through_a_symlink_planted_at_the_target_path
    with_path do |path|
      victim = "#{path}.victim"
      File.write(victim, "untouched")
      File.symlink(victim, path)
      url = "https://api.github.com/repos/acme/widgets/actions/runs"

      cache = Owlook::GithubCache.new(path)
      cache.store(url, etag: '"abc123"', body: "{}")
      cache.save

      refute_predicate File.lstat(path), :symlink?, "the symlink should have been replaced, not written through"
      assert_equal "untouched", File.read(victim)
    end
  end

  def test_save_writes_the_file_with_0600_not_a_world_or_group_readable_mode
    with_path do |path|
      cache = Owlook::GithubCache.new(path)
      cache.store("https://example.com", etag: '"abc123"', body: "{}")

      cache.save

      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  private

  def with_path
    Dir.mktmpdir do |dir|
      yield File.join(dir, "github_cache.json")
    end
  end
end
