# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class Owlook::CollectorTest < Minitest::Test
  def test_poll_ci_once_records_an_observation_per_project_and_writes_the_state_file
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new({
          ["acme", "widgets", "main"] => {
            head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael",
            jobs: [
              { name: "test", status: "completed", conclusion: "success", steps: [] },
              { name: "lint", status: "completed", conclusion: "success", steps: [] },
              { name: "deploy", status: "completed", conclusion: "skipped", steps: [] }
            ]
          }
        })
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once

        on_disk = JSON.parse(File.read(state_path))
        ci_rows = on_disk.select { |e| e["kind"] == "ci" }
        assert_equal 1, ci_rows.size
        entry = ci_rows.first
        assert_equal "acme/widgets", entry["project"]
        assert_equal "ci", entry["kind"]
        assert_equal "main", entry["branch"]
        assert_nil entry["destination"]
        assert_equal "abc123", entry["version"]
        assert_equal "success", entry["state"]
        assert_equal "rafael", entry["author"]
        assert_equal "github", entry["source"]
        # skipped jobs don't count against the total the way a failure
        # would — GitHub's own UI treats a run with only skips as green too.
        assert_equal({ "jobs_total" => 3, "jobs_passed" => 2, "jobs_skipped" => 1 }, entry["details"])

        # A project-level "ci_timing" row rides along too — how long this
        # cycle actually took (see Collector#record_timing).
        timing = on_disk.find { |e| e["kind"] == "ci_timing" }
        assert timing, "expected a ci_timing row"
        assert_kind_of Numeric, timing["details"]["duration_seconds"]
      end
    end
  end

  # A branch the store has never seen gets an immediate "checking" row,
  # written before the real GitHub calls even start — same reason
  # poll_queues_once announces a destination before its real check. GitHub
  # Actions is fast, but a project's tab shouldn't say "no CI runs found"
  # for however briefly it takes to find out otherwise.
  def test_poll_ci_once_writes_a_checking_placeholder_before_the_real_check_completes
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      writer = RecordingWriter.new
      github_source = FakeGithubSource.new(
        ["acme", "widgets", "main"] => { head_sha: "abc123", status: "completed", conclusion: "success",
          updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
      )
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: github_source
      )

      collector.poll_ci_once

      checking_writes = writer.snapshots.select { |snap| snap.any? { |row| row[:state] == "checking" } }
      assert_equal 1, checking_writes.size, "expected exactly one write with a checking placeholder"

      final = writer.snapshots.last
      assert_equal "success", final.find { |row| row[:branch] == "main" }[:state]
    end
  end

  def test_poll_ci_once_does_not_reannounce_an_already_known_branch
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      writer = RecordingWriter.new
      github_source = FakeGithubSource.new(
        ["acme", "widgets", "main"] => { head_sha: "abc123", status: "completed", conclusion: "success",
          updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
      )
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: github_source
      )

      collector.poll_ci_once
      collector.poll_ci_once

      checking_writes = writer.snapshots.select { |snap| snap.any? { |row| row[:state] == "checking" } }
      assert_equal 1, checking_writes.size, "a known branch should never be reset to checking"
    end
  end

  # Regression: the checking placeholder used to stamp `timestamp: Time.now`.
  # A real run's timestamp is GitHub's own updated_at — the underlying
  # event's time, not "when the collector saw it" — which is very often
  # older than "right now" (nobody's pushed to this branch in days). Store
  # only keeps whichever observation has the newer timestamp, so a
  # placeholder stamped "now" would outrank a real-but-old run and never
  # get replaced.
  def test_poll_ci_once_replaces_the_checking_placeholder_even_when_the_real_run_is_old
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          ["acme", "widgets", "main"] => { head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2020-01-01T00:00:00Z", actor: "rafael" } # years old, well before "now"
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once

        on_disk = JSON.parse(File.read(state_path))
        entry = on_disk.find { |row| row["branch"] == "main" }
        assert_equal "success", entry["state"]
        assert_equal "abc123", entry["version"]
      end
    end
  end

  # A project with no Actions runs yet still gets a row — not a silent
  # skip. Otherwise it has no CI row and (usually) no queue row either, so
  # it's invisible to the widget: no tab, no "0 tracked", nothing to
  # distinguish "nothing has run yet" from "never configured at all".
  def test_poll_ci_once_records_a_no_runs_row_when_a_project_has_no_workflow_runs
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}) # no runs for any project
        )

        collector.poll_ci_once

        on_disk = JSON.parse(File.read(state_path))
        entry = on_disk.find { |e| e["kind"] == "ci" }
        assert_equal "acme/widgets", entry["project"]
        assert_equal "ci", entry["kind"]
        assert_equal "main", entry["branch"]
        assert_equal "no_runs", entry["state"]
        assert_nil entry["version"]
        assert_nil entry["author"]
        assert_equal({}, entry["details"])
      end
    end
  end

  def test_poll_ci_once_skips_a_project_with_no_github_remote_and_continues
    Dir.mktmpdir do |dir|
      no_remote_project = File.join(dir, "no-remote")
      init_repo(no_remote_project, remote: nil, branch: "main")

      with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |good_project|
        state_path = File.join(dir, "state.json")
        github_source = FakeGithubSource.new(
          ["acme", "widgets", "main"] => {
            head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael"
          }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [no_remote_project, good_project]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once

        on_disk = JSON.parse(File.read(state_path))
        ci_rows = on_disk.select { |e| e["kind"] == "ci" }
        assert_equal 1, ci_rows.size
        assert_equal "acme/widgets", ci_rows.first["project"]
      end
    end
  end

  def test_poll_queues_once_records_one_observation_per_destination
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => ["default", "staging"]),
          queue_source: FakeQueueSource.new(
            ["default"] => { ready: 2, failed: 0 },
            ["staging"] => { ready: 0, failed: 3 }
          )
        )

        collector.poll_queues_once

        on_disk = JSON.parse(File.read(state_path))
        queue_rows = on_disk.select { |e| e["kind"] == "queue" }.sort_by { |e| e["destination"] }
        assert_equal 2, queue_rows.size

        default_row, staging_row = queue_rows
        assert_equal "acme/widgets", default_row["project"]
        assert_equal "queue", default_row["kind"]
        assert_equal "ok", default_row["state"]
        assert_equal({ "ready" => 2, "failed" => 0 }, default_row["details"])

        assert_equal "failing", staging_row["state"]
        assert_equal({ "ready" => 0, "failed" => 3 }, staging_row["details"])

        # A project-level "queue_timing" row rides along too — how long
        # this cycle actually took (see Collector#record_timing).
        timing = on_disk.find { |e| e["kind"] == "queue_timing" }
        assert timing, "expected a queue_timing row"
        assert_kind_of Numeric, timing["details"]["duration_seconds"]
      end
    end
  end

  # OWLOOK_QUEUE_POLL_INTERVAL's default was picked as an estimate, never
  # measured against a real server (see README) — this is what makes that
  # measurable without guessing: the actual cycle duration lands in the
  # journal every time.
  def test_poll_queues_once_logs_how_long_the_cycle_took
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        logged = []
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => ["default"]),
          queue_source: FakeQueueSource.new(["default"] => { ready: 0, failed: 0 }),
          logger: ->(message) { logged << message }
        )

        collector.poll_queues_once

        assert logged.any? { |m| m.match?(/queue poll cycle finished in \d+(\.\d+)?s/) },
          "expected a cycle-duration log line, got: #{logged.inspect}"
      end
    end
  end

  # A destination the store has never seen before gets an immediate
  # "checking" row, written before the (slow, SSH-based) real check even
  # starts — otherwise the very first thing a freshly-started collector
  # writes for that destination is nothing at all, and the widget can't
  # tell "not checked yet" from "not configured".
  def test_poll_queues_once_writes_a_checking_placeholder_before_the_real_check_completes
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      writer = RecordingWriter.new
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: FakeGithubSource.new({}),
        kamal_source: FakeKamalSource.new(project_path => ["default"]),
        queue_source: FakeQueueSource.new(["default"] => { ready: 2, failed: 0 })
      )

      collector.poll_queues_once

      checking_writes = writer.snapshots.select { |snap| snap.any? { |row| row[:state] == "checking" } }
      assert_equal 1, checking_writes.size, "expected exactly one write with a checking placeholder"

      final = writer.snapshots.last
      assert_equal "ok", final.find { |row| row[:destination] == "default" }[:state]
    end
  end

  # Re-announcing an already-known destination as "checking" on every
  # cycle would flash real data back to a loading state every 60s —
  # Store#record always keeps the newer timestamp, and "checking" always
  # timestamps as "now".
  def test_poll_queues_once_does_not_reannounce_an_already_known_destination
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      writer = RecordingWriter.new
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: FakeGithubSource.new({}),
        kamal_source: FakeKamalSource.new(project_path => ["default"]),
        queue_source: FakeQueueSource.new(["default"] => { ready: 2, failed: 0 })
      )

      collector.poll_queues_once
      collector.poll_queues_once

      checking_writes = writer.snapshots.select { |snap| snap.any? { |row| row[:state] == "checking" } }
      assert_equal 1, checking_writes.size, "a known destination should never be reset to checking"
    end
  end

  # A project with zero Kamal destinations has nothing real to report a
  # duration for — no queue_timing row, not one claiming 0.0s.
  def test_poll_queues_once_records_no_timing_when_there_are_no_destinations
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new({})
        )

        collector.poll_queues_once

        refute File.exist?(state_path), "nothing to report, nothing to write"
      end
    end
  end

  # A project whose workflows are wired to more than one branch (master ->
  # production, staging -> staging) gets a CI row for each — the branch
  # checked out locally is no longer the only thing that decides what's
  # polled.
  def test_poll_ci_once_polls_every_branch_a_workflow_pushes_to
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          ["acme", "widgets", "master"] => { head_sha: "aaa111", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
          ["acme", "widgets", "staging"] => { head_sha: "bbb222", status: "completed", conclusion: "failure",
            updated_at: "2026-08-26T12:05:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => ["master", "staging"])
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }.sort_by { |e| e["branch"] }
        assert_equal 2, ci_rows.size
        assert_equal ["master", "staging"], ci_rows.map { |e| e["branch"] }
        assert_equal "success", ci_rows.find { |e| e["branch"] == "master" }["state"]
        assert_equal "failure", ci_rows.find { |e| e["branch"] == "staging" }["state"]
      end
    end
  end

  # A project with no push-triggered workflow (PR-only CI, or none at all)
  # falls back to whatever's checked out locally instead of tracking
  # nothing — same single-branch behavior as before Sources::Workflows
  # existed.
  def test_poll_ci_once_falls_back_to_the_checked_out_branch_without_a_push_workflow
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          ["acme", "widgets", "main"] => { head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new({})
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }
        assert_equal 1, ci_rows.size
        assert_equal "main", ci_rows.first["branch"]
      end
    end
  end

  # With the widget's "all branches" setting on, every branch with a
  # recent run is polled — dependabot included — instead of only the ones
  # a push-triggered workflow names.
  def test_poll_ci_once_polls_every_branch_with_a_run_when_all_branches_setting_is_on
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          {
            ["acme", "widgets", "master"] => { head_sha: "aaa111", status: "completed", conclusion: "success",
              updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
            ["acme", "widgets", "dependabot/bundler/rails-8.1"] => { head_sha: "ccc333", status: "completed",
              conclusion: "success", updated_at: "2026-08-26T12:10:00Z", actor: "dependabot[bot]" }
          },
          { ["acme", "widgets"] => ["master", "dependabot/bundler/rails-8.1"] }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => ["master", "staging"]),
          settings_loader: -> { FakeSettings.new(all_branches: true) }
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }.sort_by { |e| e["branch"] }
        assert_equal ["dependabot/bundler/rails-8.1", "master"], ci_rows.map { |e| e["branch"] }
      end
    end
  end

  # The setting being on doesn't help when GitHub has no run history at
  # all yet — falls back the same way the default mode does.
  def test_poll_ci_once_falls_back_when_all_branches_setting_is_on_but_nothing_has_ever_run
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          ["acme", "widgets", "staging"] => { head_sha: "bbb222", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => ["staging"]),
          settings_loader: -> { FakeSettings.new(all_branches: true) }
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }
        assert_equal 1, ci_rows.size
        assert_equal "staging", ci_rows.first["branch"]
      end
    end
  end

  # A silently-skipped destination looks identical to one nobody's checked
  # yet — the widget can't tell "SSH is broken" from "no data so far". Record
  # what happened instead of omitting the row.
  def test_poll_queues_once_records_an_unreachable_row_when_a_check_fails_and_continues
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => [project_path]}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => ["default", "staging"]),
          queue_source: FakeQueueSource.new(["default"] => { ready: 2, failed: 0 }) # "staging" not stubbed -> fails
        )

        collector.poll_queues_once

        queue_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "queue" }.sort_by { |e| e["destination"] }
        assert_equal 2, queue_rows.size

        default_row, staging_row = queue_rows
        assert_equal "ok", default_row["state"]

        assert_equal "unreachable", staging_row["state"]
        assert_equal "queue", staging_row["kind"]
        assert_includes staging_row["details"]["error"], "not stubbed"
      end
    end
  end

  # config.yml is read once per poll, not once at construction — so adding a
  # project to it takes effect on the next cycle (well within 30s), not only
  # after a systemctl restart. No file-watching needed: the collector is
  # already looping this often anyway.
  def test_poll_ci_once_picks_up_config_changes_without_being_reconstructed
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          ["acme", "widgets", "main"] => {
            head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael"
          }
        )
        projects = []
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({"projects" => projects}) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once
        refute File.exist?(state_path), "nothing configured yet, nothing to write"

        projects << project_path
        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }
        assert_equal 1, ci_rows.size
        assert_equal "acme/widgets", ci_rows.first["project"]
      end
    end
  end

  # #run's sleep, tested in isolation the same way poll_ci_once/
  # poll_queues_once are — no real waiting, no infinite loop.
  def test_wait_for_next_poll_wakes_up_early_when_the_all_branches_setting_changes
    values = [false, false, true, true] # unchanged, unchanged, then flips
    call = -1
    sleeps = []
    collector = build_collector(
      settings_loader: -> { call += 1; FakeSettings.new(all_branches: values[[call, values.size - 1].min]) },
      sleeper: ->(seconds) { sleeps << seconds }
    )

    collector.send(:wait_for_next_poll, 30, tick: 10)

    # Two 10s ticks (20s), not the full three it'd take to reach 30 —
    # the third tick is where the setting changed, so it stops there.
    assert_equal [10, 10], sleeps
  end

  def test_wait_for_next_poll_runs_the_full_interval_when_nothing_changes
    sleeps = []
    collector = build_collector(
      settings_loader: -> { FakeSettings.new(all_branches: false) },
      sleeper: ->(seconds) { sleeps << seconds }
    )

    collector.send(:wait_for_next_poll, 25, tick: 10)

    # 10 + 10 + 5 = 25 — the last tick is capped to whatever's left,
    # not a full 10s past the interval.
    assert_equal [10, 10, 5], sleeps
  end

  private

  # writer's path is never touched — none of the tests that use this write
  # a snapshot (StateWriter only hits disk inside #write), so there's no
  # need for a real tmpdir here.
  def build_collector(**overrides)
    Owlook::Collector.new(
      **{
        config_loader: -> { Owlook::Config.new({"projects" => []}) },
        store: Owlook::Store.new,
        writer: Owlook::StateWriter.new("/tmp/owlook-test-unused-state.json"),
        github_source: FakeGithubSource.new({})
      }.merge(overrides)
    )
  end

  def with_project(remote:, branch:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "project")
      init_repo(path, remote: remote, branch: branch)
      yield path
    end
  end

  def init_repo(path, remote:, branch:)
    FileUtils.mkdir_p(path)
    Dir.chdir(path) do
      system("git", "init", "-q", "-b", branch)
      system("git", "config", "user.email", "test@example.com")
      system("git", "config", "user.name", "Test")
      File.write("README.md", "hi")
      system("git", "add", "README.md")
      system("git", "commit", "-q", "-m", "init")
      system("git", "remote", "add", "origin", remote) if remote
    end
  end

  # Routes latest_run(owner:, repo:, branch:) to canned results, keyed by
  # [owner, repo, branch]. Missing key means "no runs" (nil), matching the
  # real Sources::GitHub contract. branches_with_runs is routed separately,
  # keyed by [owner, repo], defaulting to [] (unstubbed = no recent runs).
  class FakeGithubSource
    # branch_routes is a plain trailing positional (not a keyword) so a
    # bare `["a", "b", "c"] => {...}` hash-rocket list at a call site still
    # collects into `routes` the old, brace-free way — a keyword parameter
    # here would make Ruby treat that trailing list as keyword arguments
    # instead once one is present, breaking every existing call site.
    def initialize(routes, branch_routes = {})
      @routes = routes
      @branch_routes = branch_routes
    end

    def latest_run(owner:, repo:, branch:)
      @routes[[owner, repo, branch]]
    end

    def branches_with_runs(owner:, repo:, limit: 100)
      @branch_routes.fetch([owner, repo], [])
    end
  end

  class FakeKamalSource
    def initialize(routes)
      @routes = routes
    end

    def destinations(project_path)
      @routes.fetch(project_path, [])
    end
  end

  # Routes branches(project_path) to canned lists. Missing key means "no
  # push-triggered workflow" ([]), matching the real Sources::Workflows
  # contract.
  class FakeWorkflowsSource
    def initialize(routes)
      @routes = routes
    end

    def branches(project_path)
      @routes.fetch(project_path, [])
    end
  end

  FakeSettings = Struct.new(:all_branches, keyword_init: true) do
    def all_branches?
      !!all_branches
    end
  end

  # A real StateWriter only exposes what's on disk right now — this
  # records every snapshot passed to #write, in order, so a test can
  # assert on the sequence of writes (e.g. "checking" landed before the
  # real result), not just the final state.
  class RecordingWriter
    attr_reader :snapshots

    def initialize
      @snapshots = []
    end

    def write(snapshot)
      @snapshots << snapshot
      true
    end
  end

  # Routes status(destination:) to canned counts, keyed by [destination].
  # A destination with no stubbed route raises, matching the real
  # Sources::Queue contract for an unreachable/misconfigured destination.
  class FakeQueueSource
    def initialize(routes)
      @routes = routes
    end

    def status(project_path:, destination:)
      @routes.fetch([destination]) { raise Owlook::Sources::Queue::CommandFailedError.new(["kamal"], FakeStatus.new(1), "not stubbed") }
    end

    FakeStatus = Struct.new(:exitstatus)
  end
end
