# frozen_string_literal: true

require "test_helper"

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
end
