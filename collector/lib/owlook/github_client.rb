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

    # A 304 only means anything if this client is the one holding what it
    # matched — GithubCache returning nothing for this exact URL means the
    # entry was evicted, never existed, or the ETag came from a different
    # cache entirely. Nothing to safely return in that case.
    class UnexpectedNotModifiedError < StandardError
      def initialize(path)
        super("GitHub responded 304 Not Modified for #{path}, but nothing is cached for it")
      end
    end

    # Real, live-confirmed behavior this depends on: a "checking" cycle
    # polling many branches every 30s with no caching at all can burn
    # through GitHub's 5000/hour primary rate limit on its own (a real
    # user's `gh` CLI got locked out — "all branches" on a project with
    # ~18 branches is ~4,440 calls/hour by itself). Owlook shares one
    # token with everything else the user runs, so it refuses to spend
    # what's left rather than risk being the reason another tool starves.
    class RateLimitExhaustedError < StandardError
      def initialize(path)
        super("GitHub API rate limit is low — skipping #{path} for the rest of this cycle")
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
    # cache/rate_limit_guard default to nil (no conditional requests, no
    # circuit breaker) rather than a hidden default instance — every real
    # caller (bin/owlook-collector) passes its own explicitly, sharing one
    # RateLimitGuard across every GithubClient call in a cycle; nil keeps
    # existing tests that construct a bare client working unchanged.
    def initialize(token:, api_base: API_BASE, cache: nil, rate_limit_guard: nil)
      @token = token
      @api_base = api_base
      @cache = cache
      @rate_limit_guard = rate_limit_guard
    end

    def get(path)
      raise RateLimitExhaustedError, path if @rate_limit_guard&.exhausted?

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

      update_rate_limit_guard(response)

      case response
      when Net::HTTPNotModified
        cached_body(uri, original_path)
      when Net::HTTPSuccess
        cache_response(uri, response)
        JSON.parse(response.body)
      when Net::HTTPRedirection
        location = response["location"]
        raise RequestError.new(original_path, response) if location.nil? || redirects_left.zero?

        fetch(URI(location), original_path, redirects_left: redirects_left - 1)
      else
        raise RequestError.new(original_path, response)
      end
    end

    # A cache miss on a 304 (the entry this ETag matched got evicted or
    # never existed) can't be trusted as "nothing changed" — there's
    # nothing to fall back to except treating it as the request failure
    # it effectively is.
    def cached_body(uri, original_path)
      body = @cache&.body_for(uri.to_s)
      raise UnexpectedNotModifiedError, original_path unless body

      JSON.parse(body)
    end

    # response.body sometimes comes back tagged ASCII-8BIT/BINARY rather
    # than UTF-8 even though GitHub's JSON always is UTF-8 (confirmed live:
    # Net::HTTP doesn't reliably honor the charset in a JSON Content-Type
    # the way it does for text/*) — JSON.generate on the cached copy later
    # warns about this today and is a hard error starting json 3.0.
    def cache_response(uri, response)
      etag = response["etag"]
      @cache&.store(uri.to_s, etag: etag, body: response.body.dup.force_encoding(Encoding::UTF_8)) if etag
    end

    # A malformed value here (never seen live, but this header comes from
    # the outside world) shouldn't cost an otherwise-good response its own
    # real data — worst case, the guard just doesn't hear about this one
    # response's quota.
    def update_rate_limit_guard(response)
      remaining = response["x-ratelimit-remaining"]
      @rate_limit_guard&.update(Integer(remaining)) if remaining
    rescue ArgumentError, TypeError
      nil
    end

    def build_request(uri)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      request["User-Agent"] = "owlook"
      etag = @cache&.etag_for(uri.to_s)
      request["If-None-Match"] = etag if etag
      request
    end
  end
end
