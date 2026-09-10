# frozen_string_literal: true

require "json"
require "securerandom"

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
    MAX_TMP_ATTEMPTS = 5

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

    # Same atomic write StateWriter uses for owlook.json, for the same
    # reason: a plain File.write follows a symlink another local user
    # pre-planted at this exact path, writing our content through it into
    # whatever file *they* chose. O_EXCL|O_NOFOLLOW make that open fail
    # instead of following it.
    def save
      tmp_path = create_tmp_file(JSON.generate(@entries))
      File.rename(tmp_path, @path)
    end

    private

    def load
      JSON.parse(SafeFile.read(@path))
    rescue Errno::ENOENT, JSON::ParserError, SafeFile::UnsafeFileError
      {}
    end

    def create_tmp_file(json)
      MAX_TMP_ATTEMPTS.times do
        candidate = "#{@path}.tmp.#{SecureRandom.hex(8)}"
        File.open(candidate, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
          file.write(json)
          file.fsync
        end
        return candidate
      rescue Errno::EEXIST
        next
      end
      raise "could not create a temp file for #{@path} after #{MAX_TMP_ATTEMPTS} attempts"
    end
  end
end
