# frozen_string_literal: true

require "test_helper"
require "support/fake_http_server"
require "tmpdir"

class Owlook::GithubClientTest < Minitest::Test
  def test_resolve_token_prefers_the_env_var
    token = Owlook::GithubClient.resolve_token(
      env: { "GITHUB_TOKEN" => "from-env" },
      gh_auth_token: -> { "from-gh" }
    )

    assert_equal "from-env", token
  end

  def test_resolve_token_falls_back_to_gh_auth_token
    token = Owlook::GithubClient.resolve_token(
      env: {},
      gh_auth_token: -> { "from-gh" }
    )

    assert_equal "from-gh", token
  end

  def test_resolve_token_raises_when_neither_source_has_one
    error = assert_raises(Owlook::GithubClient::MissingTokenError) do
      Owlook::GithubClient.resolve_token(env: {}, gh_auth_token: -> { "" })
    end

    assert_includes error.message, "GITHUB_TOKEN"
  end

  # Reproduces the real bug live-traced against rpaweb/skeletor-mailing-list
  # (renamed to rpaweb/pragon-landing on GitHub, local git remote never
  # updated): GitHub's REST API answers a request against the old repo name
  # with a real 301 to the canonical /repositories/{id}/... URL. A client
  # that treats any non-2xx as a hard failure never gets the real data —
  # exactly the "stuck on checking forever" symptom the user reported.
  def test_get_follows_a_real_301_redirect_to_the_canonical_url
    server = Owlook::FakeHttpServer.new
    server
      .respond_with(301, headers: { "Location" => "#{server.base_url}/repositories/761806454/actions/runs" })
      .respond_with(200, body: '{"total_count": 0, "workflow_runs": []}')
      .start

    client = Owlook::GithubClient.new(token: "fake-token", api_base: server.base_url)
    result = client.get("/repos/rpaweb/skeletor-mailing-list/actions/runs")

    server.stop

    assert_equal({ "total_count" => 0, "workflow_runs" => [] }, result)
  end

  def test_get_raises_after_too_many_redirects_instead_of_looping_forever
    server = Owlook::FakeHttpServer.new
    6.times { server.respond_with(301, headers: { "Location" => "#{server.base_url}/somewhere-else" }) }
    server.start

    client = Owlook::GithubClient.new(token: "fake-token", api_base: server.base_url)

    assert_raises(Owlook::GithubClient::RequestError) { client.get("/repos/x/y") }
    server.stop
  end

  # Confirmed live against the real GitHub API before writing this: a 304
  # Not Modified response, sent because If-None-Match matched, does not
  # consume any rate-limit quota at all — this whole mechanism exists
  # because of that. A real user's `gh` CLI got locked out after leaving
  # "all branches" on: with ~18 branches, that's ~4,440 calls/hour from a
  # single project, no caching at all — this is the fix for it.
  def test_get_sends_if_none_match_when_the_cache_has_an_etag_for_this_url
    with_cache do |cache|
      server = Owlook::FakeHttpServer.new
      server.respond_with(200, headers: { "ETag" => '"abc123"' }, body: "{}").start
      cache.store("#{server.base_url}/repos/acme/widgets/actions/runs", etag: '"abc123"', body: "{}")

      client = Owlook::GithubClient.new(token: "fake-token", api_base: server.base_url, cache: cache)
      client.get("/repos/acme/widgets/actions/runs")

      server.stop

      assert_equal '"abc123"', server.received_requests.first[:headers]["if-none-match"]
    end
  end

  def test_get_stores_the_etag_and_body_from_a_fresh_200_response
    with_cache do |cache|
      server = Owlook::FakeHttpServer.new
      server.respond_with(200, headers: { "ETag" => '"new-etag"' }, body: '{"total_count":1}').start
      url = "#{server.base_url}/repos/acme/widgets/actions/runs"

      client = Owlook::GithubClient.new(token: "fake-token", api_base: server.base_url, cache: cache)
      result = client.get("/repos/acme/widgets/actions/runs")

      server.stop

      assert_equal({ "total_count" => 1 }, result)
      assert_equal '"new-etag"', cache.etag_for(url)
      assert_equal '{"total_count":1}', cache.body_for(url)
    end
  end

  def test_get_returns_the_cached_body_on_a_304_instead_of_the_empty_response
    with_cache do |cache|
      server = Owlook::FakeHttpServer.new
      server.respond_with(304).start
      url = "#{server.base_url}/repos/acme/widgets/actions/runs"
      cache.store(url, etag: '"abc123"', body: '{"total_count":0,"workflow_runs":[]}')

      client = Owlook::GithubClient.new(token: "fake-token", api_base: server.base_url, cache: cache)
      result = client.get("/repos/acme/widgets/actions/runs")

      server.stop

      assert_equal({ "total_count" => 0, "workflow_runs" => [] }, result)
    end
  end

  def test_get_raises_on_a_304_with_nothing_cached_for_that_url
    with_cache do |cache|
      server = Owlook::FakeHttpServer.new
      server.respond_with(304).start

      client = Owlook::GithubClient.new(token: "fake-token", api_base: server.base_url, cache: cache)

      assert_raises(Owlook::GithubClient::UnexpectedNotModifiedError) { client.get("/repos/acme/widgets/actions/runs") }
      server.stop
    end
  end

  def test_get_updates_the_rate_limit_guard_from_the_response_header
    server = Owlook::FakeHttpServer.new
    server.respond_with(200, headers: { "X-RateLimit-Remaining" => "5" }, body: "{}").start
    guard = Owlook::RateLimitGuard.new(threshold: 200)

    client = Owlook::GithubClient.new(token: "fake-token", api_base: server.base_url, rate_limit_guard: guard)
    client.get("/repos/acme/widgets/actions/runs")

    server.stop

    assert_predicate guard, :exhausted?
  end

  # No fake server started at all — proves the request is never actually
  # attempted once the guard has tripped, not just that the eventual
  # response gets ignored.
  def test_get_raises_immediately_without_a_request_once_the_guard_is_exhausted
    guard = Owlook::RateLimitGuard.new(threshold: 200)
    guard.update(1)
    client = Owlook::GithubClient.new(token: "fake-token", api_base: "http://127.0.0.1:1", rate_limit_guard: guard)

    assert_raises(Owlook::GithubClient::RateLimitExhaustedError) { client.get("/repos/acme/widgets/actions/runs") }
  end

  private

  def with_cache
    Dir.mktmpdir do |dir|
      yield Owlook::GithubCache.new(File.join(dir, "github_cache.json"))
    end
  end
end
