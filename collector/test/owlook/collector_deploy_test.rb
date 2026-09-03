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
# poll_queues_once's DEPLOY half — recording, freshness against CI/tags,
# placeholders, and unreachable handling. See collector_queue_test.rb for
# the QUEUE half of the same method.
class Owlook::CollectorDeployTest < Minitest::Test
  include Owlook::CollectorTestSupport

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

  # End to end, not a DeployFreshness-in-isolation test (that lives in
  # deploy_freshness_test.rb) — a real CI observation and a real deploy
  # observation, from the same collector's own Store, actually meeting
  # in the middle: the deployed SHA is a real, older commit in this
  # project's real git history, one commit behind what CI just verified
  # for "main".
  def test_poll_queues_once_records_how_far_a_deploy_is_behind_the_branch_ci_verified
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      older_sha = `git -C #{project_path} rev-parse HEAD`.strip
      Dir.chdir(project_path) do
        File.write("second.txt", "hi")
        system("git", "add", "second.txt")
        system("git", "commit", "-q", "-m", "second commit")
      end
      newer_sha = `git -C #{project_path} rev-parse HEAD`.strip

      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          %w[acme widgets main] => { head_sha: newer_sha, status: "completed", conclusion: "success",
                                     updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          kamal_source: FakeKamalSource.new(project_path => ["production"]),
          queue_source: FakeQueueSource.new(["production"] => { ready: 0, failed: 0 }),
          deploy_source: FakeDeploySource.new(["production"] => older_sha)
        )

        collector.poll_ci_once
        collector.poll_queues_once

        deploy_row = JSON.parse(File.read(state_path)).find { |e| e["kind"] == "deploy" }

        assert_equal "main", deploy_row["details"]["fresh_ref"]
        assert_equal 1, deploy_row["details"]["behind"]
      end
    end
  end

  # Real scenario: a destination whose actual deploy trigger is a git tag
  # (`on: push: tags: 'v*'`), not a branch — confirmed live against
  # Luxtown's own production, whose deployed SHA matched its latest tag
  # exactly while `main` had already moved on. The tag has to win here
  # even though `main` is also a real ancestor, since it's the nearer
  # (and the actually-relevant) match.
  def test_poll_queues_once_prefers_the_latest_tag_over_the_branch_when_a_destination_deploys_from_a_tag
    with_project(remote: "https://github.com/acme/widgets.git", branch: "main") do |project_path|
      tagged_sha = `git -C #{project_path} rev-parse HEAD`.strip
      Dir.chdir(project_path) { system("git", "tag", "v1.0.0", tagged_sha) }
      Dir.chdir(project_path) do
        File.write("second.txt", "hi")
        system("git", "add", "second.txt")
        system("git", "commit", "-q", "-m", "second commit")
      end
      newer_sha = `git -C #{project_path} rev-parse HEAD`.strip

      Dir.mktmpdir do |state_dir|
        state_path = File.join(state_dir, "state.json")
        github_source = FakeGithubSource.new(
          %w[acme widgets main] => { head_sha: newer_sha, status: "completed", conclusion: "success",
                                     updated_at: "2026-08-26T12:00:00Z", actor: "rafael" }
        )
        collector = Owlook::Collector.new(
          config_loader: -> { Owlook::Config.new({ "projects" => [project_path] }) },
          store: Owlook::Store.new,
          writer: Owlook::StateWriter.new(state_path),
          github_source: github_source,
          kamal_source: FakeKamalSource.new(project_path => ["production"]),
          queue_source: FakeQueueSource.new(["production"] => { ready: 0, failed: 0 }),
          deploy_source: FakeDeploySource.new(["production"] => tagged_sha)
        )

        collector.poll_ci_once
        collector.poll_queues_once

        deploy_row = JSON.parse(File.read(state_path)).find { |e| e["kind"] == "deploy" }

        assert_equal "v1.0.0", deploy_row["details"]["fresh_ref"]
        assert_equal 0, deploy_row["details"]["behind"]
      end
    end
  end
end
