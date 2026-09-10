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
    # A dependabot/renovate branch that gets merged/closed simply stops
    # appearing in branches_with_runs — nothing ever tells this class that
    # URL is gone, so without an expiry it would accumulate garbage
    # entries forever under exactly the branch-churn scenario this cache
    # exists to help with. A week comfortably outlives any real gap in
    # polling (a rate-limit-guard-skipped cycle, a shell restart) while
    # still bounding growth for a genuinely abandoned branch.
    RETENTION = 7 * 24 * 60 * 60 # seconds

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
      @entries[url] = { "etag" => etag, "body" => body, "stored_at" => Time.now.to_i }
    end

    # Same atomic write StateWriter uses for owlook.json, for the same
    # reason: a plain File.write follows a symlink another local user
    # pre-planted at this exact path, writing our content through it into
    # whatever file *they* chose. O_EXCL|O_NOFOLLOW make that open fail
    # instead of following it.
    def save
      prune!
      tmp_path = create_tmp_file(JSON.generate(@entries))
      File.rename(tmp_path, @path)
    end

    private

    # A file whose content is syntactically valid JSON but the wrong
    # shape (a bare `null`, an Array — disk corruption, a manual edit, an
    # incompatible future format) parses cleanly, so JSON::ParserError
    # never catches it; every entries.dig/[]= call downstream would then
    # raise on a non-Hash. Same "not safe to trust, treat as empty"
    # response as the exceptions already rescued below.
    def load
      parsed = JSON.parse(SafeFile.read(@path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue Errno::ENOENT, JSON::ParserError, SafeFile::UnsafeFileError
      {}
    end

    # An entry with no "stored_at" (written by a version of this class
    # before that field existed) is treated as already-expired rather
    # than kept indefinitely — safe either way, since a pruned entry just
    # means the next request for that URL is a normal GET instead of a
    # free 304.
    def prune!
      cutoff = Time.now.to_i - RETENTION
      @entries.reject! { |_url, entry| (entry["stored_at"] || 0) < cutoff }
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
