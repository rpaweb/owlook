# frozen_string_literal: true

module Owlook
  # Runs an external command with a hard wall-clock deadline and a cap on
  # how much output it can produce — used everywhere Owlook shells out to
  # something on the other end of a connection it doesn't control (SSH to
  # a Kamal destination, `git fetch` against a remote). Open3.capture3
  # blocks and buffers forever by default: a hostile or merely hung
  # endpoint wedges the collector's whole cycle indefinitely, or exhausts
  # memory on unbounded output — neither needs a malicious remote
  # specifically, a server that accepts the connection and never writes
  # back produces the same hang with completely ordinary tools.
  #
  # Timeout.timeout is deliberately not used here: it only unblocks the
  # Ruby thread waiting on the child, it doesn't touch the child process
  # itself — a `kamal app exec` left running past its own deadline stays
  # alive, still holding whatever connection it opened. pgroup: true
  # makes the spawned process (and anything it goes on to fork, like
  # `kamal`'s own SSH subprocess) the leader of its own process group, so
  # a timeout can kill that whole group, not just the direct child.
  class BoundedCommand
    class TimeoutError < StandardError; end
    class OutputTooLargeError < StandardError; end

    DEFAULT_TIMEOUT = 30 # seconds
    DEFAULT_MAX_BYTES = 1 * 1024 * 1024 # 1 MiB per stream

    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

    def self.run(*command, chdir:, env: {}, timeout: DEFAULT_TIMEOUT, max_bytes: DEFAULT_MAX_BYTES)
      new(timeout: timeout, max_bytes: max_bytes).run(*command, chdir: chdir, env: env)
    end

    def initialize(timeout: DEFAULT_TIMEOUT, max_bytes: DEFAULT_MAX_BYTES)
      @timeout = timeout
      @max_bytes = max_bytes
    end

    def run(*command, chdir:, env: {})
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      # command is always an argv array (>= 2 elements, confirmed at
      # every call site: Sources::Queue/Deploy's build_command,
      # DeployFreshness's literal git argv, this file's own tests).
      # Process.spawn given more than one string argument execs
      # directly, never through a shell — the injection the rule below
      # guards against needs a single interpolated command *string*,
      # which nothing here ever builds.
      # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
      pid = Process.spawn(env, *command, chdir: chdir, out: out_w, err: err_w, pgroup: true)
      out_w.close
      err_w.close

      begin
        stdout, stderr = read_bounded(out_r, err_r)
      rescue TimeoutError, OutputTooLargeError
        kill_group(pid)
        raise
      end

      _pid, status = Process.wait2(pid)
      Result.new(stdout: stdout, stderr: stderr, status: status)
    ensure
      out_r&.close
      err_r&.close
    end

    private

    def read_bounded(out_r, err_r)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      buffers = { out_r => +"", err_r => +"" }
      open_ios = [out_r, err_r]

      until open_ios.empty?
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise TimeoutError, "timed out after #{@timeout}s" if remaining <= 0

        ready, = IO.select(open_ios, nil, nil, remaining)
        ready&.each { |io| drain(io, buffers, open_ios) }
      end

      [buffers[out_r], buffers[err_r]]
    end

    def drain(io, buffers, open_ios)
      buffers[io] << io.read_nonblock(65_536)
      return unless buffers[io].bytesize > @max_bytes

      raise OutputTooLargeError, "output exceeded #{@max_bytes} bytes"
    rescue EOFError
      open_ios.delete(io)
    rescue IO::WaitReadable
      nil
    end

    # TERM first, so a well-behaved child (kamal, ssh) gets a chance to
    # clean up its own connection; KILL after a short grace period for
    # whatever doesn't. The leading "-" targets the process group pgroup:
    # true created, not just the direct child pid.
    def kill_group(pid)
      Process.kill("-TERM", pid)
      sleep 0.2
      Process.kill("-KILL", pid)
    rescue Errno::ESRCH
      nil
    ensure
      begin
        Process.wait2(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
