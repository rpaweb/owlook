# frozen_string_literal: true

require "fileutils"

module Owlook
  # Resolves (and verifies) the directories owlook keeps its own files in,
  # outside of ~/.config/owlook (user-authored, never touched by this
  # module).
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

    # For the state file: rebuilt from scratch every ~30s cycle (see
    # bin/owlook-collector), so there's nothing lost by tying it to
    # something that doesn't survive a logout.
    #
    # $XDG_RUNTIME_DIR is the right home for this (tmpfs, wiped on logout,
    # already 0700-owned-by-you under any systemd session) — but a
    # collector invoked outside a full session can have it unset. The old
    # fallback was the world-writable /tmp, shared by every user on the
    # machine: a predictable file name there lets another local user plant
    # a symlink ahead of us and have StateWriter's write follow it into a
    # file *they* chose. The fallback here is the same per-user cache
    # directory #resolve_cache_dir always uses — never a shared,
    # world-writable path.
    def self.resolve(env: ENV, uid: Process.uid)
      prepare(env["XDG_RUNTIME_DIR"] || cache_home(env), uid)
    end

    # For data meant to actually survive between collector cycles —
    # GithubCache's ETags, whose whole point is still being there on the
    # next cycle, and whose own retention window is measured in days.
    # $XDG_RUNTIME_DIR would quietly defeat that: it's tmpfs, wiped on
    # every logout/reboot, so a 7-day retention would rarely ever get to
    # matter. Always ~/.cache/owlook instead, matching the same
    # config-vs-cache-vs-runtime split ~/.config/owlook already implies.
    def self.resolve_cache_dir(env: ENV, uid: Process.uid)
      prepare(cache_home(env), uid)
    end

    def self.cache_home(env)
      File.join(env.fetch("HOME") { Dir.home }, ".cache", "owlook")
    end
    private_class_method :cache_home

    def self.prepare(path, uid)
      FileUtils.mkdir_p(path, mode: 0o700)
      verify(path, uid)
      path
    end
    private_class_method :prepare

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
