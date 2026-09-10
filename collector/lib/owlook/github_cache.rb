# frozen_string_literal: true

require "json"

module Owlook
  # Persists GitHub API ETags (and the body they matched) across collector
  # cycles, keyed by full request URL. Without this, conditional requests
  # (see GithubClient) would never actually save anything: bin/owlook-
  # collector is a fresh process every 30s, not a long-lived daemon — an
  # in-memory cache would be empty on every single invocation.
  #
  # A corrupt or missing file is treated as "nothing cached yet", same
  # semantics Store/StateWriter already use for their own state file — a
  # bad cache degrades to "every request goes through as a normal GET",
  # never a hard failure.
  class GithubCache
    def initialize(path)
      @path = path
      @entries = load
    end

    def etag_for(url)
      @entries.dig(url, "etag")
    end

    def body_for(url)
      @entries.dig(url, "body")
    end

    def store(url, etag:, body:)
      @entries[url] = { "etag" => etag, "body" => body }
    end

    def save
      File.write(@path, JSON.generate(@entries))
    end

    private

    def load
      JSON.parse(SafeFile.read(@path))
    rescue Errno::ENOENT, JSON::ParserError, SafeFile::UnsafeFileError
      {}
    end
  end
end
