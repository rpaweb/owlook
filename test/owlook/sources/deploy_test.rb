# frozen_string_literal: true

require "test_helper"

class Owlook::Sources::DeployTest < Minitest::Test
  def test_version_parses_a_bare_sha_line
    shell = FakeShell.new("44d49f4ed11652b520c00e6ee35d848e5a217fc5\n")
    source = Owlook::Sources::Deploy.new(shell: shell)

    sha = source.version(project_path: "/tmp/widgets", destination: "production")

    assert_equal "44d49f4ed11652b520c00e6ee35d848e5a217fc5", sha
  end

  # Real output (confirmed live, not guessed): kamal app version's own
  # "INFO [...] Running/Finished..." log lines and an "App Host: <ip>"
  # line surround the one line that's actually the SHA.
  def test_version_skips_kamals_own_log_lines
    output = <<~OUTPUT
        INFO [f8eda941] Running /usr/bin/env sh -c '...' on 67.205.129.106
        INFO [f8eda941] Finished in 2.510 seconds with exit status 0 (successful).
      App Host: 67.205.129.106
      44d49f4ed11652b520c00e6ee35d848e5a217fc5
    OUTPUT
    shell = FakeShell.new(output)
    source = Owlook::Sources::Deploy.new(shell: shell)

    sha = source.version(project_path: "/tmp/widgets", destination: "production")

    assert_equal "44d49f4ed11652b520c00e6ee35d848e5a217fc5", sha
  end

  # A multi-host destination reports one SHA line per host — same
  # simplification Sources::Queue makes for a multi-role destination's
  # repeated JSON lines: take the first.
  def test_version_takes_the_first_sha_when_multiple_hosts_report
    output = "44d49f4ed11652b520c00e6ee35d848e5a217fc5\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
    shell = FakeShell.new(output)
    source = Owlook::Sources::Deploy.new(shell: shell)

    sha = source.version(project_path: "/tmp/widgets", destination: "production")

    assert_equal "44d49f4ed11652b520c00e6ee35d848e5a217fc5", sha
  end

  def test_version_raises_when_no_sha_is_found
    shell = FakeShell.new("nothing here looks like a git sha\n")
    source = Owlook::Sources::Deploy.new(shell: shell)

    assert_raises(Owlook::Sources::Deploy::NoVersionFoundError) do
      source.version(project_path: "/tmp/widgets", destination: "production")
    end
  end

  def test_version_raises_when_the_command_fails
    shell = FailingShell.new
    source = Owlook::Sources::Deploy.new(shell: shell)

    assert_raises(Owlook::Sources::Deploy::CommandFailedError) do
      source.version(project_path: "/tmp/widgets", destination: "production")
    end
  end

  def test_version_runs_in_the_project_directory
    shell = FakeShell.new("44d49f4ed11652b520c00e6ee35d848e5a217fc5\n")
    source = Owlook::Sources::Deploy.new(shell: shell)

    source.version(project_path: "/tmp/widgets", destination: "production")

    assert_equal "/tmp/widgets", shell.last_chdir
  end

  def test_version_passes_destination_for_a_named_destination
    shell = FakeShell.new("44d49f4ed11652b520c00e6ee35d848e5a217fc5\n")
    source = Owlook::Sources::Deploy.new(shell: shell)

    source.version(project_path: "/tmp/widgets", destination: "production")

    assert_includes shell.last_command, "--destination"
    assert_includes shell.last_command, "production"
  end

  def test_version_omits_destination_flag_for_default
    shell = FakeShell.new("44d49f4ed11652b520c00e6ee35d848e5a217fc5\n")
    source = Owlook::Sources::Deploy.new(shell: shell)

    source.version(project_path: "/tmp/widgets", destination: "default")

    refute_includes shell.last_command, "--destination"
  end

  class FakeShell
    attr_reader :last_command, :last_chdir

    def initialize(output)
      @output = output
    end

    def call(command, chdir:)
      @last_command = command
      @last_chdir = chdir
      @output
    end
  end

  FakeStatus = Struct.new(:exitstatus)

  class FailingShell
    def call(*)
      raise Owlook::Sources::Deploy::CommandFailedError.new(["kamal"], FakeStatus.new(1), "boom")
    end
  end
end
