# frozen_string_literal: true

module Owlook
  # Ensures only one collector cycle runs at a time across every instance
  # of the widget on this machine — not just within a single one.
  #
  # BarWidget.qml's own Timer+Process already stops a single instance from
  # overlapping itself (see its `if (!collectorProcess.running)` guard),
  # but that guard is per-instance, in-memory, and Quickshell instantiates
  # the whole widget (Timer included) once per screen: Bar.qml renders via
  # `Variants { model: Quickshell.screens }`, and its own ModuleList
  # comment says the identical thing about mounting a module twice — "two
  # of every timer and fetch behind them". A 2-monitor setup means 2
  # independent 30s timers, each spawning its own bin/owlook-collector,
  # both reading/writing the same shared state file with no coordination
  # at all. Confirmed live: this is exactly what caused a real user's
  # desktop to show the same transition notified twice — both instances
  # raced to read the same "before" state and both called Notifier.
  #
  # flock, not a PID or "does this file exist" lock: those need their own
  # staleness logic (what if the process that made the file died?) — a
  # flock is tied to the holding process's own open file description and
  # is released by the kernel the instant that process exits, for any
  # reason, crash included. Nothing here can ever leave a stale lock
  # behind for a later cycle to get stuck on.
  class CollectorLock
    def initialize(path)
      @path = path
    end

    # Runs the block and returns true only if this process is the sole
    # holder of the lock right now. Returns false, without running the
    # block, if another instance already holds it — that instance is
    # already doing this exact cycle's work from the same shared state,
    # so there is nothing for this one to contribute by also doing it.
    def run_exclusively
      File.open(@path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |file|
        return false unless file.flock(File::LOCK_EX | File::LOCK_NB)

        yield
        true
      end
    rescue Errno::ELOOP
      # Another local user planted a symlink at this exact path. Unlike
      # GithubCache/StateWriter, there's no content here to trust or
      # distrust — the only thing at stake is whether two instances might
      # race this one cycle, which is exactly today's pre-this-fix
      # behavior. Running without the lock this once is a safer response
      # than either following the symlink or refusing to poll at all.
      yield
      true
    end
  end
end
