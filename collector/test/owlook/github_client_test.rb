# frozen_string_literal: true

require "test_helper"
require "support/fake_http_server"

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
end
