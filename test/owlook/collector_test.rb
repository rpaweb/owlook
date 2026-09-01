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
                                               %w[acme widgets main] => {
                                                 head_sha: "abc123", status: "completed", conclusion: "success",
                                                 updated_at: "2026-08-26T12:00:00Z", actor: "rafael",
                                                 jobs: [
                                                   { name: "test", status: "completed", conclusion: "success",
                                                     steps: [] },
                                                   { name: "lint", status: "completed", conclusion: "success",
                                                     steps: [] },
                                                   { name: "deploy", status: "completed", conclusion: "skipped",
                                                     steps: [] }
                                                 ]
                                               }
                                             })
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
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

  # The value wait_for_next_poll compares against on every tick to catch a
  # config.yml edit early (see its own test) — has to be set from a real
  # poll, not just read fresh at comparison time, for the same reason
  # @known_all_branches is.
  def test_poll_ci_once_remembers_the_project_list_it_just_read
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      collector = build_collector(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) }
      )

      collector.poll_ci_once

      assert_equal [project_path], collector.instance_variable_get(:@known_projects)
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
        %w[acme widgets main] => { head_sha: "abc123", status: "completed", conclusion: "success",
                                   updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
      )
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
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
        %w[acme widgets main] => { head_sha: "abc123", status: "completed", conclusion: "success",
                                   updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
      )
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
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
          %w[acme widgets main] => { head_sha: "abc123", status: "completed", conclusion: "success",
                                     updated_at: "2020-01-01T00:00:00Z", actor: "rafael" } # years old, well before "now"
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
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
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
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
          %w[acme widgets main] => {
            head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael"
          }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [no_remote_project, good_project] }) },
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
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => %w[default staging]),
          queue_source: FakeQueueSource.new(
            ["default"] => { ready: 2, failed: 0 },
            ["staging"] => { ready: 0, failed: 3 }
          ),
          deploy_source: FakeDeploySource.new({})
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

  # Before this, a destination's state was only ever "failing" or "ok" —
  # a backlog with jobs waiting and zero workers alive to run them
  # silently read as "ok", since nothing had technically failed yet.
  def test_poll_queues_once_marks_a_destination_stalled_when_jobs_are_ready_with_no_workers
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => %w[stalled busy idle]),
          queue_source: FakeQueueSource.new(
            # Ready jobs, nobody to work them.
            ["stalled"] => { ready: 5, failed: 0, workers: 0 },
            # Ready jobs, but workers are alive — not stalled, just busy.
            ["busy"] => { ready: 5, failed: 0, workers: 2 },
            # Nothing waiting and no workers — nothing to be stalled about.
            ["idle"] => { ready: 0, failed: 0, workers: 0 }
          ),
          deploy_source: FakeDeploySource.new({})
        )

        collector.poll_queues_once

        rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "queue" }
        states = rows.to_h { |row| [row["destination"], row["state"]] }

        assert_equal "stalled", states["stalled"]
        assert_equal "ok", states["busy"]
        assert_equal "ok", states["idle"]
      end
    end
  end

  # An actual failure is the more urgent fact — it wins over "stalled"
  # even when both conditions are technically true at once.
  def test_poll_queues_once_prefers_failing_over_stalled_when_both_apply
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => %w[default]),
          queue_source: FakeQueueSource.new(["default"] => { ready: 5, failed: 1, workers: 0 }),
          deploy_source: FakeDeploySource.new({})
        )

        collector.poll_queues_once

        row = JSON.parse(File.read(state_path)).find { |e| e["kind"] == "queue" }

        assert_equal "failing", row["state"]
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
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => ["default"]),
          queue_source: FakeQueueSource.new(["default"] => { ready: 0, failed: 0 }),
          deploy_source: FakeDeploySource.new({}),
          logger: ->(message) { logged << message }
        )

        collector.poll_queues_once

        assert logged.any? { |m| m.match?(/queue poll cycle finished in \d+(\.\d+)?s/) },
               "expected a cycle-duration log line, got: #{logged.inspect}"
      end
    end
  end

  # Same fix, same reason, as the CI side (see
  # test_poll_ci_once_polls_branches_concurrently_not_one_at_a_time):
  # kamal app exec is a real SSH round-trip per destination, and
  # Sources::Queue#status has no shared mutable state to make concurrent
  # calls unsafe (a fresh Open3.capture3 subprocess every time, same
  # shape as GithubClient's fresh Net::HTTP.start per call).
  def test_poll_queues_once_polls_destinations_concurrently_not_one_at_a_time
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        destinations = %w[production staging preview]
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => destinations),
          queue_source: SlowQueueSource.new(delay: 0.04, destinations: destinations),
          deploy_source: FakeDeploySource.new({})
        )

        started = Time.now
        collector.poll_queues_once
        elapsed = Time.now - started

        # Sequential would be >= 3 * 0.04 = 0.12s. 0.12s of headroom over
        # the ~0.04s concurrent ideal, matching the CI-side version of this
        # test — the comment here used to claim that headroom while the
        # threshold was actually 0.1s (less than the CI test's), which is
        # exactly the kind of margin a busier CI runner can eat (confirmed
        # live: a real run took 0.17s and failed).
        assert_operator elapsed, :<, 0.12,
                        "expected concurrent destination polling, took #{elapsed.round(3)}s for 3 destinations at 0.04s each"

        queue_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "queue" }

        assert_equal destinations.sort, queue_rows.map { |e| e["destination"] }.sort
      end
    end
  end

  # A project with far more destinations than max_concurrent_requests
  # shouldn't fire them all at once — same reasoning as the CI-side cap
  # test below, applied to the queue side for consistency (see
  # poll_destinations_concurrently's own comment on why this side is
  # lower-risk in practice, but capped the same way regardless).
  def test_poll_queues_once_caps_concurrent_destination_polling
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      destinations = (1..10).map { |i| "dest-#{i}" }
      probe = ConcurrencyProbe.new
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
        store: Owlook::Store.new,
        writer: Owlook::StateWriter.new("/tmp/owlook-test-unused-state.json"),
        github_source: FakeGithubSource.new({}),
        kamal_source: FakeKamalSource.new(project_path => destinations),
        queue_source: ProbingQueueSource.new(delay: 0.02, destinations: destinations, probe: probe),
        deploy_source: FakeDeploySource.new({}),
        max_concurrent_requests: 3
      )

      collector.poll_queues_once

      assert_operator probe.max, :<=, 3, "expected at most 3 destinations in flight at once"
      assert_operator probe.max, :>, 1, "expected real concurrency, not accidentally serialized"
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
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: FakeGithubSource.new({}),
        kamal_source: FakeKamalSource.new(project_path => ["default"]),
        queue_source: FakeQueueSource.new(["default"] => { ready: 2, failed: 0 }),
        deploy_source: FakeDeploySource.new({})
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
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: FakeGithubSource.new({}),
        kamal_source: FakeKamalSource.new(project_path => ["default"]),
        queue_source: FakeQueueSource.new(["default"] => { ready: 2, failed: 0 }),
        deploy_source: FakeDeploySource.new({})
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
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new({})
        )

        collector.poll_queues_once

        refute_path_exists state_path, "nothing to report, nothing to write"
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
          %w[acme widgets master] => { head_sha: "aaa111", status: "completed", conclusion: "success",
                                       updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
          %w[acme widgets staging] => { head_sha: "bbb222", status: "completed", conclusion: "failure",
                                        updated_at: "2026-08-26T12:05:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => %w[master staging])
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }.sort_by { |e| e["branch"] }

        assert_equal 2, ci_rows.size
        assert_equal(%w[master staging], ci_rows.map { |e| e["branch"] })
        assert_equal "success", ci_rows.find { |e| e["branch"] == "master" }["state"]
        assert_equal "failure", ci_rows.find { |e| e["branch"] == "staging" }["state"]
      end
    end
  end

  # The real bug this covers: a broad-mode poll of N branches previously
  # took N round-trips, back to back — during which the collector couldn't
  # notice a settings-toggle click either (see wait_for_next_poll's own
  # comment for that half of it). Branches are polled concurrently now, so
  # 5 branches at ~40ms each finishes in about one branch's time, not the
  # sum of all five.
  def test_poll_ci_once_polls_branches_concurrently_not_one_at_a_time
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        branches = %w[a b c d e]
        github_source = SlowGithubSource.new(delay: 0.04, branches: branches)
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => branches)
        )

        started = Time.now
        collector.poll_ci_once
        elapsed = Time.now - started

        # Sequential would be >= 5 * 0.04 = 0.2s; concurrent should land
        # close to a single branch's delay. 0.12s leaves real headroom for
        # thread scheduling/CI-machine jitter without being able to pass
        # if this silently regressed back to sequential.
        assert_operator elapsed, :<, 0.12,
                        "expected concurrent branch polling, took #{elapsed.round(3)}s for 5 branches at 0.04s each"

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }

        assert_equal branches.sort, ci_rows.map { |e| e["branch"] }.sort
      end
    end
  end

  # The real motivation for MAX_CONCURRENT_REQUESTS: a repo with hundreds
  # of branches (a broad-mode poll of something the size of rails/rails,
  # say) shouldn't fire one request per branch all at once — that risks
  # tripping GitHub's secondary/abuse rate limiting, a different
  # mechanism than the 5000/hour primary limit. max_concurrent_requests
  # is injected small here so the cap is observable without needing
  # anywhere near that many real branches/threads in a test.
  def test_poll_ci_once_caps_concurrent_branch_polling
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      branches = (1..10).map { |i| "branch-#{i}" }
      probe = ConcurrencyProbe.new
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
        store: Owlook::Store.new,
        writer: Owlook::StateWriter.new("/tmp/owlook-test-unused-state.json"),
        github_source: ProbingGithubSource.new(delay: 0.02, branches: branches, probe: probe),
        workflows_source: FakeWorkflowsSource.new(project_path => branches),
        max_concurrent_requests: 3
      )

      collector.poll_ci_once

      assert_operator probe.max, :<=, 3, "expected at most 3 branches in flight at once"
      assert_operator probe.max, :>, 1, "expected real concurrency, not accidentally serialized"
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
          %w[acme widgets main] => { head_sha: "abc123", status: "completed", conclusion: "success",
                                     updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
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
            %w[acme widgets master] => { head_sha: "aaa111", status: "completed", conclusion: "success",
                                         updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
            ["acme", "widgets", "dependabot/bundler/rails-8.1"] => { head_sha: "ccc333", status: "completed",
                                                                     conclusion: "success", updated_at: "2026-08-26T12:10:00Z", actor: "dependabot[bot]" }
          },
          { %w[acme widgets] => ["master", "dependabot/bundler/rails-8.1"] }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => %w[master staging]),
          settings_loader: -> { FakeSettings.new(all_branches: true) }
        )

        collector.poll_ci_once

        ci_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }.sort_by { |e| e["branch"] }

        assert_equal(["dependabot/bundler/rails-8.1", "master"], ci_rows.map { |e| e["branch"] })
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
          %w[acme widgets staging] => { head_sha: "bbb222", status: "completed", conclusion: "success",
                                        updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
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

  # Flipping the toggle back off must not leave a dependabot branch it
  # discovered sitting in the state file forever — nothing else ever
  # prunes a Store entry, so Collector has to forget and re-announce.
  def test_poll_ci_once_forgets_branches_no_longer_relevant_when_all_branches_setting_changes
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          {
            %w[acme widgets master] => { head_sha: "aaa111", status: "completed", conclusion: "success",
                                         updated_at: "2026-08-26T12:00:00Z", actor: "rafael" },
            ["acme", "widgets", "dependabot/bundler/rails-8.1"] => { head_sha: "ccc333", status: "completed",
                                                                     conclusion: "success", updated_at: "2026-08-26T12:10:00Z", actor: "dependabot[bot]" }
          },
          { %w[acme widgets] => ["master", "dependabot/bundler/rails-8.1"] }
        )
        all_branches = false
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          workflows_source: FakeWorkflowsSource.new(project_path => ["master"]),
          settings_loader: -> { FakeSettings.new(all_branches: all_branches) }
        )

        collector.poll_ci_once

        assert_equal ["master"], ci_branches(state_path)

        all_branches = true
        collector.poll_ci_once

        assert_equal ["dependabot/bundler/rails-8.1", "master"], ci_branches(state_path)

        all_branches = false
        collector.poll_ci_once

        assert_equal ["master"], ci_branches(state_path),
                     "the dependabot branch should be forgotten, not left over from all-branches mode"
      end
    end
  end

  def test_poll_ci_once_does_not_notify_on_the_first_ever_result
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        notifier = FakeNotifier.new
        # Already failing the very first time owlook ever checks it —
        # not news, since there's nothing to compare it against yet.
        github_source = FakeGithubSource.new(
          %w[acme widgets main] => { head_sha: "aaa", status: "completed", conclusion: "failure",
                                     updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(File.join(state_dir, "state.json")),
          github_source: github_source,
          notifier: notifier
        )

        collector.poll_ci_once

        assert_empty notifier.sent
      end
    end
  end

  def test_poll_ci_once_notifies_when_ci_transitions_from_passing_to_failing
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        notifier = FakeNotifier.new
        routes = {
          %w[acme widgets main] => { head_sha: "aaa", status: "completed", conclusion: "success",
                                     updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        }
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(File.join(state_dir, "state.json")),
          github_source: FakeGithubSource.new(routes),
          notifier: notifier
        )

        collector.poll_ci_once

        assert_empty notifier.sent, "no notification for the first-ever result"

        routes[%w[acme widgets main]] = { head_sha: "bbb", status: "completed", conclusion: "failure",
                                          updated_at: "2026-08-26T12:05:00Z", actor: "rafael" }
        collector.poll_ci_once

        assert_equal 1, notifier.sent.size
        sent = notifier.sent.first

        assert_equal "Owlook — acme/widgets", sent.headline
        assert_includes sent.description, "main"
        assert_includes sent.description, "failure"
        assert_equal "critical", sent.urgency
      end
    end
  end

  def test_poll_ci_once_notifies_on_recovery_from_failing_to_passing
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        notifier = FakeNotifier.new
        routes = {
          %w[acme widgets main] => { head_sha: "aaa", status: "completed", conclusion: "failure",
                                     updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        }
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(File.join(state_dir, "state.json")),
          github_source: FakeGithubSource.new(routes),
          notifier: notifier
        )

        collector.poll_ci_once

        assert_empty notifier.sent, "no notification for the first-ever result"

        routes[%w[acme widgets main]] = { head_sha: "bbb", status: "completed", conclusion: "success",
                                          updated_at: "2026-08-26T12:05:00Z", actor: "rafael" }
        collector.poll_ci_once

        assert_equal 1, notifier.sent.size
        sent = notifier.sent.first

        assert_includes sent.description, "back to normal"
        assert_equal "normal", sent.urgency
      end
    end
  end

  def test_poll_ci_once_does_not_notify_when_the_state_is_unchanged
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        notifier = FakeNotifier.new
        routes = {
          %w[acme widgets main] => { head_sha: "aaa", status: "completed", conclusion: "failure",
                                     updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        }
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(File.join(state_dir, "state.json")),
          github_source: FakeGithubSource.new(routes),
          notifier: notifier
        )

        collector.poll_ci_once # first-ever result, already excluded

        # Still failing, just a newer run of the same conclusion.
        routes[%w[acme widgets main]] = { head_sha: "bbb", status: "completed", conclusion: "failure",
                                          updated_at: "2026-08-26T12:05:00Z", actor: "rafael" }
        collector.poll_ci_once

        assert_empty notifier.sent, "a repeat of the same state should never notify"
      end
    end
  end

  # A branch that has never had a run isn't "nothing to compare against" —
  # "no_runs" is itself a real, previously observed result (owlook checked
  # and there was genuinely nothing), so a branch going from that straight
  # to failing is real news, unlike the still-"checking" case above.
  def test_poll_ci_once_notifies_when_a_never_run_branch_starts_failing
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        notifier = FakeNotifier.new
        routes = {}
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(File.join(state_dir, "state.json")),
          github_source: FakeGithubSource.new(routes),
          notifier: notifier
        )

        collector.poll_ci_once

        assert_empty notifier.sent, "no_runs is not itself notification-worthy"

        routes[%w[acme widgets main]] = { head_sha: "aaa", status: "completed", conclusion: "failure",
                                          updated_at: "2026-08-26T12:05:00Z", actor: "rafael" }
        collector.poll_ci_once

        assert_equal 1, notifier.sent.size
      end
    end
  end

  def test_poll_queues_once_notifies_when_a_destination_transitions_to_failing
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        notifier = FakeNotifier.new
        counts = { ready: 0, failed: 0 }
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(File.join(state_dir, "state.json")),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => ["default"]),
          queue_source: FakeQueueSource.new(["default"] => counts),
          deploy_source: FakeDeploySource.new({}),
          notifier: notifier
        )

        collector.poll_queues_once

        assert_empty notifier.sent, "no notification for the first-ever check"

        counts[:failed] = 4
        collector.poll_queues_once

        assert_equal 1, notifier.sent.size
        sent = notifier.sent.first

        assert_includes sent.description, "default"
        assert_equal "critical", sent.urgency
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
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => %w[default staging]),
          queue_source: FakeQueueSource.new(["default"] => { ready: 2, failed: 0 }), # "staging" not stubbed -> fails
          deploy_source: FakeDeploySource.new({})
        )

        collector.poll_queues_once

        queue_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "queue" }
        queue_rows = queue_rows.sort_by { |e| e["destination"] }

        assert_equal 2, queue_rows.size

        default_row, staging_row = queue_rows

        assert_equal "ok", default_row["state"]

        assert_equal "unreachable", staging_row["state"]
        assert_equal "queue", staging_row["kind"]
        assert_includes staging_row["details"]["error"], "not stubbed"
      end
    end
  end

  # Runs alongside the queue check, not instead of it — same poll cycle
  # produces both a "queue" and a "deploy" row per destination.
  def test_poll_queues_once_records_a_deploy_observation_per_destination
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => %w[default staging]),
          queue_source: FakeQueueSource.new(["default"] => { ready: 0, failed: 0 }, ["staging"] => { ready: 0, failed: 0 }),
          deploy_source: FakeDeploySource.new(
            ["default"] => "44d49f4ed11652b520c00e6ee35d848e5a217fc5",
            ["staging"] => "f22ab54907423f2bdf39159ed8a04fa027f67736"
          )
        )

        collector.poll_queues_once

        deploy_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "deploy" }
        deploy_rows = deploy_rows.sort_by { |e| e["destination"] }

        assert_equal 2, deploy_rows.size

        default_row, staging_row = deploy_rows

        assert_equal "acme/widgets", default_row["project"]
        assert_equal "ok", default_row["state"]
        assert_equal "44d49f4ed11652b520c00e6ee35d848e5a217fc5", default_row["version"]

        assert_equal "ok", staging_row["state"]
        assert_equal "f22ab54907423f2bdf39159ed8a04fa027f67736", staging_row["version"]
      end
    end
  end

  def test_poll_queues_once_writes_a_deploy_checking_placeholder_before_the_real_check_completes
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      writer = RecordingWriter.new
      collector = Owlook::Collector.new(
        config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
        store: Owlook::Store.new,
        writer: writer,
        github_source: FakeGithubSource.new({}),
        kamal_source: FakeKamalSource.new(project_path => ["default"]),
        queue_source: FakeQueueSource.new(["default"] => { ready: 0, failed: 0 }),
        deploy_source: FakeDeploySource.new(["default"] => "44d49f4ed11652b520c00e6ee35d848e5a217fc5")
      )

      collector.poll_queues_once

      checking_writes = writer.snapshots.select { |snap| snap.any? { |row| row[:kind] == "deploy" && row[:state] == "checking" } }

      assert_equal 1, checking_writes.size, "expected exactly one write with a deploy checking placeholder"

      final = writer.snapshots.last

      assert_equal "ok", final.find { |row| row[:kind] == "deploy" && row[:destination] == "default" }[:state]
    end
  end

  def test_poll_queues_once_records_an_unreachable_deploy_row_when_the_check_fails
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => ["default"]),
          queue_source: FakeQueueSource.new(["default"] => { ready: 0, failed: 0 }),
          deploy_source: FakeDeploySource.new({}) # not stubbed -> fails
        )

        collector.poll_queues_once

        row = JSON.parse(File.read(state_path)).find { |e| e["kind"] == "deploy" }

        assert_equal "unreachable", row["state"]
        assert_includes row["details"]["error"], "not stubbed"
      end
    end
  end

  # The real bug this covers: notify_on_transition used to label every
  # non-CI observation "queue" — a deploy transition would have shown up
  # in a desktop notification as "queue production: unreachable" instead
  # of "deploy production: unreachable".
  def test_poll_queues_once_labels_a_deploy_notification_as_deploy_not_queue
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      Dir.mktmpdir do |state_dir|
        notifier = FakeNotifier.new
        deploy_routes = { ["default"] => "44d49f4ed11652b520c00e6ee35d848e5a217fc5" }
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(File.join(state_dir, "state.json")),
          github_source: FakeGithubSource.new({}),
          kamal_source: FakeKamalSource.new(project_path => ["default"]),
          queue_source: FakeQueueSource.new(["default"] => { ready: 0, failed: 0 }),
          deploy_source: FakeDeploySource.new(deploy_routes),
          notifier: notifier
        )

        collector.poll_queues_once

        assert_empty notifier.sent, "no notification for the first-ever check"

        deploy_routes.delete(["default"]) # next check fails -> unreachable
        collector.poll_queues_once

        sent = notifier.sent.find { |n| n.description.include?("deploy") }

        assert sent, "expected a deploy notification, got: #{notifier.sent.map(&:description)}"
        assert_includes sent.description, "deploy default"
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
          %w[acme widgets main] => {
            head_sha: "abc123", status: "completed", conclusion: "success",
            updated_at: "2026-08-26T12:00:00Z", actor: "rafael"
          }
        )
        projects = []
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => projects }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source
        )

        collector.poll_ci_once

        refute_path_exists state_path, "nothing configured yet, nothing to write"

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
    values = [false, true, true] # unchanged, then flips
    call = -1
    sleeps = []
    collector = build_collector(
      settings_loader: lambda {
        call += 1
        FakeSettings.new(all_branches: values[[call, values.size - 1].min])
      },
      sleeper: ->(seconds) { sleeps << seconds }
    )
    # Primed the way sync_all_branches_setting would leave it after a real
    # poll — @known_all_branches, not a baseline re-read at call time (see
    # wait_for_next_poll's own comment for the real bug that distinction
    # fixed: a toggle flipped during a blocking queue/broad-CI poll was
    # already reflected in shell.json by the time a freshly-captured
    # baseline would have read it, so it looked unchanged for the rest of
    # that wait).
    collector.instance_variable_set(:@known_all_branches, false)
    # Also primed to match build_collector's default config_loader ([]) —
    # otherwise the project-list check (unprimed @known_projects is nil)
    # would itself fire on the very first tick, for the wrong reason.
    collector.instance_variable_set(:@known_projects, [])

    collector.send(:wait_for_next_poll, 30, tick: 10)

    # One 10s tick, not the full three it'd take to reach 30 — the second
    # tick is where the setting changed, so it stops there.
    assert_equal [10, 10], sleeps
  end

  def test_wait_for_next_poll_runs_the_full_interval_when_nothing_changes
    sleeps = []
    collector = build_collector(
      settings_loader: -> { FakeSettings.new(all_branches: false) },
      sleeper: ->(seconds) { sleeps << seconds }
    )
    collector.instance_variable_set(:@known_all_branches, false)
    collector.instance_variable_set(:@known_projects, [])

    collector.send(:wait_for_next_poll, 25, tick: 10)

    # 10 + 10 + 5 = 25 — the last tick is capped to whatever's left,
    # not a full 10s past the interval.
    assert_equal [10, 10, 5], sleeps
  end

  def test_wait_for_next_poll_wakes_up_early_when_the_setting_changed_while_it_wasnt_watching
    # The exact race the fix above addresses: nothing changes during any
    # tick this method sees, because the change already happened before
    # this method was ever called (e.g. during a blocking queue poll) —
    # @known_all_branches still holds the pre-change value, so the very
    # first tick catches it.
    sleeps = []
    collector = build_collector(
      settings_loader: -> { FakeSettings.new(all_branches: true) },
      sleeper: ->(seconds) { sleeps << seconds }
    )
    collector.instance_variable_set(:@known_all_branches, false)

    collector.send(:wait_for_next_poll, 30, tick: 10)

    assert_equal [10], sleeps
  end

  # Same fast-path as the all_branches setting, for a different trigger —
  # adding (or removing) a project in config.yml shouldn't sit behind up to
  # ci_interval of nothing visibly happening before its tab and "checking"
  # spinner show up (see announce_new_ci_branches).
  def test_wait_for_next_poll_wakes_up_early_when_the_project_list_changes
    project_lists = [["a"], %w[a b], %w[a b]] # unchanged, then "b" is added
    call = -1
    sleeps = []
    collector = build_collector(
      config_loader: lambda {
        call += 1
        Owlook::Config.new({ "projects" => project_lists[[call, project_lists.size - 1].min] })
      },
      settings_loader: -> { FakeSettings.new(all_branches: false) },
      sleeper: ->(seconds) { sleeps << seconds }
    )
    collector.instance_variable_set(:@known_all_branches, false)
    # Primed the way poll_ci_once would leave it after a real poll — see
    # the all_branches test above for why this can't be a baseline re-read.
    collector.instance_variable_set(:@known_projects, Owlook::Config.new({ "projects" => ["a"] }).projects)

    collector.send(:wait_for_next_poll, 30, tick: 10)

    # One 10s tick, not the full three — the second tick is where "b" got
    # added, so it stops there.
    assert_equal [10, 10], sleeps
  end

  def test_wait_for_next_poll_wakes_up_early_when_the_project_list_changed_while_it_wasnt_watching
    # Same race as the all_branches version: the change already happened
    # before this method was ever called (e.g. during a blocking queue
    # poll), so @known_projects still holds the pre-change list and the
    # very first tick catches it.
    sleeps = []
    collector = build_collector(
      config_loader: -> { Owlook::Config.new({ "projects" => %w[a b] }) },
      settings_loader: -> { FakeSettings.new(all_branches: false) },
      sleeper: ->(seconds) { sleeps << seconds }
    )
    collector.instance_variable_set(:@known_all_branches, false)
    collector.instance_variable_set(:@known_projects, Owlook::Config.new({ "projects" => ["a"] }).projects)

    collector.send(:wait_for_next_poll, 30, tick: 10)

    assert_equal [10], sleeps
  end

  # The gap wait_for_next_poll's own project-list fast-path didn't
  # cover: CI notices a newly-added project quickly, but queues only ran
  # on their own next_queue_check schedule regardless — confirmed live,
  # a new project's QUEUES section sat on "checking" far longer than its
  # CI section did.
  def test_run_one_cycle_polls_queues_immediately_when_the_project_list_just_changed
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_a|
      with_project(remote: "https://github.com/acme/gadgets.git", branch: "main") do |project_b|
        Dir.mktmpdir do |state_dir|
          state_path = File.join(state_dir, "state.json")
          project_lists = [[project_a], [project_a, project_b]]
          call = -1
          collector = Owlook::Collector.new(
            config_loader: lambda {
              call += 1
              Owlook::Config.new({ "projects" => project_lists[[call, project_lists.size - 1].min] })
            },
            store: Owlook::Store.new,
            writer: Owlook::StateWriter.new(state_path),
            github_source: FakeGithubSource.new({}),
            kamal_source: FakeKamalSource.new(project_a => ["default"], project_b => ["default"]),
            queue_source: FakeQueueSource.new(["default"] => { ready: 0, failed: 0 }),
            deploy_source: FakeDeploySource.new({})
          )
          far_future = Time.now + 3600
          # Primed the way a real poll would leave it — @known_projects
          # starts nil, so an unprimed first call would always look
          # "changed" (nil != anything), which is correct for a real
          # startup but not what cycle 1 below means to exercise.
          collector.instance_variable_set(:@known_projects, Owlook::Config.new({ "projects" => [project_a] }).projects)

          # Cycle 1: only project_a known yet, and nothing says queues are
          # due — next_queue_check should carry through unchanged.
          next_check = collector.send(:run_one_cycle, queue_interval: 60, next_queue_check: far_future)

          assert_equal far_future, next_check
          queue_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "queue" }

          assert_empty queue_rows

          # Cycle 2: config now includes project_b too. Even with
          # next_queue_check still an hour out, the new project's queues
          # get checked this cycle, not on the old schedule.
          next_check = collector.send(:run_one_cycle, queue_interval: 60, next_queue_check: far_future)

          # Queues actually ran this cycle (proven below by project_b's
          # row existing) instead of carrying the stale far-future value
          # through untouched, the way cycle 1 did.
          assert_operator next_check, :<, far_future
          queue_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "queue" }

          assert_includes queue_rows.map { |row| row["project"] }, "acme/gadgets"
        end
      end
    end
  end

  private

  def ci_branches(state_path)
    JSON.parse(File.read(state_path)).select { |e| e["kind"] == "ci" }.map { |e| e["branch"] }.sort
  end

  # writer's path is never touched — none of the tests that use this write
  # a snapshot (StateWriter only hits disk inside #write), so there's no
  # need for a real tmpdir here.
  def build_collector(**overrides)
    Owlook::Collector.new(
      config_loader: -> { Owlook::Config.new({ "projects" => [] }) },
      store: Owlook::Store.new,
      writer: Owlook::StateWriter.new("/tmp/owlook-test-unused-state.json"),
      github_source: FakeGithubSource.new({}), **overrides
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

  # Every branch reports success after a real sleep — proving branches
  # are actually polled concurrently (real wall-clock time, not just
  # interleaved) needs a fake that actually blocks, not an instant one.
  class SlowGithubSource
    def initialize(delay:, branches:)
      @delay = delay
      @branches = branches
    end

    def latest_run(owner:, repo:, branch:)
      sleep(@delay)
      return nil unless @branches.include?(branch)

      { head_sha: "sha-#{branch}", status: "completed", conclusion: "success",
        updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
    end
  end

  # Tracks how many #track blocks are in flight at once. Proves both
  # halves of a concurrency-cap claim at the same time: max stays at or
  # under the configured limit (the cap holds) and max is still above 1
  # (real concurrency is happening, not accidentally serialized down to
  # one-at-a-time by a bug in the cap itself).
  class ConcurrencyProbe
    def initialize
      @mutex = Mutex.new
      @current = 0
      @max = 0
    end

    def track
      @mutex.synchronize do
        @current += 1
        @max = @current if @current > @max
      end
      yield
    ensure
      @mutex.synchronize { @current -= 1 }
    end

    attr_reader :max
  end

  # Same shape as SlowGithubSource, but reports concurrency-in-flight to a
  # ConcurrencyProbe instead of just sleeping — needed to prove
  # work_concurrently's cap actually holds, not just that polling is
  # concurrent at all.
  class ProbingGithubSource
    def initialize(delay:, branches:, probe:)
      @delay = delay
      @branches = branches
      @probe = probe
    end

    def latest_run(owner:, repo:, branch:)
      @probe.track do
        sleep(@delay)
        next nil unless @branches.include?(branch)

        { head_sha: "sha-#{branch}", status: "completed", conclusion: "success",
          updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
      end
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

  # Records every call instead of actually shelling out to
  # omarchy-notification-send — a Ruby test suite must never pop a real
  # desktop notification.
  class FakeNotifier
    Notification = Struct.new(:headline, :description, :urgency, keyword_init: true)
    attr_reader :sent

    def initialize
      @sent = []
    end

    def notify(headline, description, urgency: "normal")
      @sent << Notification.new(headline: headline, description: description, urgency: urgency)
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

  class FakeDeploySource
    def initialize(routes)
      @routes = routes
    end

    def version(project_path:, destination:)
      @routes.fetch([destination]) { raise Owlook::Sources::Deploy::CommandFailedError.new(["kamal"], FakeStatus.new(1), "not stubbed") }
    end

    FakeStatus = Struct.new(:exitstatus)
  end

  # Every destination reports a clean queue after a real sleep — same
  # role as SlowGithubSource, proving destinations are actually polled
  # concurrently (real wall-clock time), not just correctly regardless of
  # order.
  class SlowQueueSource
    def initialize(delay:, destinations:)
      @delay = delay
      @destinations = destinations
    end

    def status(project_path:, destination:)
      sleep(@delay)
      raise Owlook::Sources::Queue::CommandFailedError.new(["kamal"], FakeQueueSource::FakeStatus.new(1), "not stubbed") \
        unless @destinations.include?(destination)

      { ready: 0, failed: 0 }
    end
  end

  # Same shape as SlowQueueSource, but reports concurrency-in-flight to a
  # ConcurrencyProbe — see ProbingGithubSource's own comment, same reason.
  class ProbingQueueSource
    def initialize(delay:, destinations:, probe:)
      @delay = delay
      @destinations = destinations
      @probe = probe
    end

    def status(project_path:, destination:)
      @probe.track do
        sleep(@delay)
        raise Owlook::Sources::Queue::CommandFailedError.new(["kamal"], FakeQueueSource::FakeStatus.new(1), "not stubbed") \
          unless @destinations.include?(destination)

        { ready: 0, failed: 0 }
      end
    end
  end
end
