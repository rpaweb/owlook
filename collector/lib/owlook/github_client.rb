# frozen_string_literal: true

require "net/http"
require "json"

module Owlook
  # Thin GitHub REST API transport. #get(path) -> parsed JSON Hash. Owns
  # nothing about what the paths mean — that's Sources::GitHub's job.
  class GithubClient
    class MissingTokenError < StandardError
      def initialize
        super("No GitHub token found: set GITHUB_TOKEN, or run `gh auth login`")
      end
    end

    class RequestError < StandardError
      def initialize(path, response)
        super("GitHub API request failed: #{path} -> #{response.code} #{response.body}")
      end
    end

    API_BASE = "https://api.github.com"
    MAX_REDIRECTS = 5

    # env and gh_auth_token are injectable so tests never shell out to the
    # real `gh` CLI or depend on the machine's actual environment.
    def self.resolve_token(env: ENV, gh_auth_token: -> { `gh auth token 2>/dev/null`.strip })
      token = env["GITHUB_TOKEN"]
      return token if token && !token.empty?

      token = gh_auth_token.call
      return token if token && !token.empty?

      raise MissingTokenError
    end

    # api_base is injectable so tests can point this at a real local fake
    # server instead of the live API — never overridden outside tests.
    def initialize(token:, api_base: API_BASE)
      @token = token
      @api_base = api_base
    end

    def get(path)
      fetch(URI("#{@api_base}#{path}"), path)
    end

    private

    # A repo renamed on GitHub still answers requests against its old name
    # with a real 301 to the canonical /repositories/{id}/... URL — live
    # confirmed against rpaweb/skeletor-mailing-list (renamed to
    # rpaweb/pragon-landing, local git remote never updated). Following it
    # here means a stale local remote degrades to "reads a bit slower",
    # not "this project's CI never resolves past a placeholder 'checking'
    # row" — the actual live symptom this fixes. Bounded so a redirect
    # loop fails loudly instead of hanging.
    def fetch(uri, original_path, redirects_left: MAX_REDIRECTS)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(build_request(uri))
      end

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      when Net::HTTPRedirection
        location = response["location"]
        raise RequestError.new(original_path, response) if location.nil? || redirects_left.zero?

        fetch(URI(location), original_path, redirects_left: redirects_left - 1)
      else
        raise RequestError.new(original_path, response)
      end
    end

    def build_request(uri)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      request["User-Agent"] = "owlook"
      request
    end
  end
end
