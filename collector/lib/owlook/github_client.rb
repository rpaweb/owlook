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

    # env and gh_auth_token are injectable so tests never shell out to the
    # real `gh` CLI or depend on the machine's actual environment.
    def self.resolve_token(env: ENV, gh_auth_token: -> { `gh auth token 2>/dev/null`.strip })
      token = env["GITHUB_TOKEN"]
      return token if token && !token.empty?

      token = gh_auth_token.call
      return token if token && !token.empty?

      raise MissingTokenError
    end

    def initialize(token:)
      @token = token
    end

    def get(path)
      uri = URI("#{API_BASE}#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      request["User-Agent"] = "owlook"

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      raise RequestError.new(path, response) unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
end
