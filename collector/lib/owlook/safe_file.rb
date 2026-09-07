# frozen_string_literal: true

module Owlook
  # A local multi-user machine lets another user plant a symlink at a
  # predictable path ahead of us — reading through it would trust
  # whatever *they* pointed it at (Store.load, StateWriter's own
  # before/after comparison), not a file this process actually wrote.
  # O_NOFOLLOW makes the open itself fail instead of following a
  # symlink; the uid check on top catches a plain (non-symlink) file
  # some other user happened to own at that exact path.
  module SafeFile
    class UnsafeFileError < StandardError
      def initialize(path, reason)
        super("refusing to trust #{path}: #{reason}")
      end
    end

    def self.read(path, uid: Process.uid)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        raise UnsafeFileError.new(path, "not a regular file") unless stat.file?
        raise UnsafeFileError.new(path, "owned by uid #{stat.uid}, not this process (#{uid})") unless stat.uid == uid

        file.read
      end
    rescue Errno::ELOOP
      raise UnsafeFileError.new(path, "is a symlink")
    end
  end
end
