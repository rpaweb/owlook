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
# Desktop-notification behavior on a real state transition — cuts across
# CI, queue, and deploy observations rather than belonging to any one of
# them, so it stays its own file instead of being split across the three.
class Owlook::CollectorNotificationsTest < Minitest::Test
  include Owlook::CollectorTestSupport

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
end
