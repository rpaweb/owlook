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

  private

  def with_path
    Dir.mktmpdir do |dir|
      yield File.join(dir, "github_cache.json")
    end
  end
end
