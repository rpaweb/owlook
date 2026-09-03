# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../support/collector_test_helpers"

# Split out of one 1600+-line collector_test.rb by concern, mirroring the
# same seams Collector's own source already has (poll_ci_once/poll_queues_once/
# deploy freshness/notifications) — not a new organizing idea, the same one
# large Ruby test suites (Rails' own AR tests, for one) already use: several
# files, each still testing the same class, split by topic rather than one
# file per class no matter how large it gets. Shared fakes/helpers live in
# collector_test_helpers.rb (test/support/), included below rather than
# redefined per file.
# poll_queues_once's own QUEUE half — recording, stalled/failing state,
# placeholders, concurrency, and per-project failure isolation. DEPLOY (the
# other half of poll_queues_once) lives in collector_deploy_test.rb; queue/
# deploy notification behavior lives in collector_notifications_test.rb.
class Owlook::CollectorQueueTest < Minitest::Test
  include Owlook::CollectorTestSupport

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

  # Same bug, same fix, one level over on the queues/deploy side —
  # @kamal_source.destinations(path) in poll_project_queues is just as
  # unguarded as branches_to_poll was.
  def test_poll_queues_once_skips_a_project_whose_own_poll_raises_but_still_polls_the_rest
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_a|
      with_project(remote: "https://github.com/acme/gadgets.git", branch: "main") do |project_b|
        Dir.mktmpdir do |state_dir|
          state_path = File.join(state_dir, "state.json")
          kamal_source = RaisingKamalSource.new(
            project_a => RuntimeError.new("kamal exec failed: connection reset"),
            project_b => ["production"]
          )
          collector = Owlook::Collector.new(
            config_loader: -> { Owlook::Config.new({ "projects" => [project_a, project_b] }) },
            store: Owlook::Store.new,
            writer: Owlook::StateWriter.new(state_path),
            github_source: FakeGithubSource.new({}),
            kamal_source: kamal_source,
            queue_source: FakeQueueSource.new(["production"] => { ready: 0, failed: 0 }),
            deploy_source: FakeDeploySource.new(["production"] => "abc123")
          )

          collector.poll_queues_once

          queue_rows = JSON.parse(File.read(state_path)).select { |e| e["kind"] == "queue" }

          assert_equal ["acme/gadgets"], queue_rows.map { |e| e["project"] }.uniq,
                       "acme/widgets' own poll blowing up shouldn't have stopped acme/gadgets from being polled"
        end
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
end
