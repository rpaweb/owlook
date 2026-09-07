# frozen_string_literal: true

require "json"
require "securerandom"

module Owlook
  # Writes a Store snapshot to disk atomically (tmp file + rename), and only
  # when the content actually changed — so the widget's FileView watcher
  # never fires for a no-op poll.
  class StateWriter
    MAX_TMP_ATTEMPTS = 5

    def initialize(path)
      @path = path
    end

    def write(snapshot)
      json = JSON.generate(snapshot)
      return false if unchanged?(json)

      write_atomically(json)
      true
    end

    private

    def unchanged?(json)
      File.exist?(@path) && SafeFile.read(@path) == json
    rescue SafeFile::UnsafeFileError
      # A file at this path that isn't safe to trust is treated the same
      # as "doesn't match" — write_atomically below replaces it outright,
      # same as it would any other stale content.
      false
    end

    def write_atomically(json)
      tmp_path = create_tmp_file(json)
      File.rename(tmp_path, @path)
    end

    # O_EXCL|O_NOFOLLOW together mean this can never open (and therefore
    # never write through) a path another local user pre-planted as a
    # symlink — the open call itself fails instead of following it,
    # rather than silently clobbering whatever that symlink points at.
    # The random suffix is defense in depth on top of that: even without
    # the flags, two collector cycles racing on one fixed ".tmp" name
    # could otherwise interleave.
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
