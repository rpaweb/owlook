# frozen_string_literal: true

require "fileutils"

module Owlook
  # Resolves (and verifies) the directory owlook's state file lives in.
  #
  # $XDG_RUNTIME_DIR is the right home for this (tmpfs, wiped on logout,
  # already 0700-owned-by-you under any systemd session) — but a
  # collector invoked outside a full session can have it unset. The old
  # fallback was the world-writable /tmp, shared by every user on the
  # machine: a predictable file name there lets another local user plant
  # a symlink ahead of us and have StateWriter's write follow it into a
  # file *they* chose. The fallback here is a per-user directory under
  # ~/.cache instead — never a shared, world-writable path.
  #
  # Either way, the directory is verified, not trusted blindly: a
  # symlink or a directory some other user owns raises rather than
  # silently writing through it. An over-permissive mode on a directory
  # this process genuinely owns is tightened in place instead of
  # raising — that's not a sign of tampering by someone else, just a
  # loose umask, and this process is allowed to chmod its own directory.
  module RuntimeDir
    class UnsafeDirectoryError < StandardError
      def initialize(path, reason)
        super("refusing to use #{path} as owlook's runtime directory: #{reason}")
      end
    end

    def self.resolve(env: ENV, uid: Process.uid)
      path = env["XDG_RUNTIME_DIR"] || File.join(env.fetch("HOME") { Dir.home }, ".cache", "owlook")
      FileUtils.mkdir_p(path, mode: 0o700)
      verify(path, uid)
      path
    end

    def self.verify(path, uid)
      stat = File.lstat(path)
      raise UnsafeDirectoryError.new(path, "is a symlink, not a real directory") if stat.symlink?
      raise UnsafeDirectoryError.new(path, "is not a directory") unless stat.directory?
      raise UnsafeDirectoryError.new(path, "owned by uid #{stat.uid}, not this user (#{uid})") unless stat.uid == uid

      File.chmod(0o700, path) if stat.mode.anybits?(0o077)
    end
    private_class_method :verify
  end
end
