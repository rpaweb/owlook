# frozen_string_literal: true

require "test_helper"

class Owlook::Sources::GitHubTest < Minitest::Test
  RUNS_RESPONSE = {
    "workflow_runs" => [
      {
        "id" => 32_993_198_471,
        "status" => "completed",
        "conclusion" => "success",
        "head_branch" => "quattro",
        "head_sha" => "0ae1694830b6bd9511042fe1b89a0062d8c083cb",
        "html_url" => "https://github.com/acme/widgets/actions/runs/32993198471",
        "triggering_actor" => { "login" => "rafael" },
        "run_started_at" => "2026-08-26T17:16:59Z",
        "updated_at" => "2026-08-26T17:19:54Z"
      }
    ]
  }.freeze

  JOBS_RESPONSE = {
    "jobs" => [
      {
        "name" => "copilot-pull-request-reviewer",
        "status" => "completed",
        "conclusion" => "success",
        "started_at" => "2026-08-26T17:17:05Z",
        "completed_at" => "2026-08-26T17:19:53Z",
        "steps" => [
          { "name" => "Set up job", "number" => 1, "status" => "completed", "conclusion" => "success" },
          { "name" => "Run tests", "number" => 2, "status" => "completed", "conclusion" => "failure" }
        ]
      }
    ]
  }.freeze

  def test_latest_run_returns_the_run_with_its_jobs_and_steps
    client = FakeClient.new(
      "/repos/acme/widgets/actions/runs?branch=quattro&per_page=1" => RUNS_RESPONSE,
      "/repos/acme/widgets/actions/runs/32993198471/jobs" => JOBS_RESPONSE
    )
    source = Owlook::Sources::GitHub.new(client: client)

    run = source.latest_run(owner: "acme", repo: "widgets", branch: "quattro")

    assert_equal 32_993_198_471, run[:id]
    assert_equal "completed", run[:status]
    assert_equal "success", run[:conclusion]
    assert_equal "0ae1694830b6bd9511042fe1b89a0062d8c083cb", run[:head_sha]
    assert_equal "https://github.com/acme/widgets/actions/runs/32993198471", run[:html_url]
    assert_equal "2026-08-26T17:19:54Z", run[:updated_at]
    assert_equal "rafael", run[:actor]

    assert_equal 1, run[:jobs].size
    job = run[:jobs].first

    assert_equal "copilot-pull-request-reviewer", job[:name]
    assert_equal "success", job[:conclusion]
    assert_equal 2, job[:steps].size
    assert_equal({ name: "Run tests", number: 2, status: "completed", conclusion: "failure" }, job[:steps][1])
  end

  def test_branches_with_runs_returns_distinct_branch_names
    client = FakeClient.new(
      "/repos/acme/widgets/actions/runs?per_page=100" => { "workflow_runs" => [
        { "head_branch" => "master" },
        { "head_branch" => "dependabot/bundler/rails-8.1" },
        { "head_branch" => "master" }
      ] }
    )
    source = Owlook::Sources::GitHub.new(client: client)

    assert_equal ["master", "dependabot/bundler/rails-8.1"],
                 source.branches_with_runs(owner: "acme", repo: "widgets")
  end

  def test_branches_with_runs_respects_a_custom_limit
    client = FakeClient.new(
      "/repos/acme/widgets/actions/runs?per_page=5" => { "workflow_runs" => [{ "head_branch" => "master" }] }
    )
    source = Owlook::Sources::GitHub.new(client: client)

    assert_equal ["master"], source.branches_with_runs(owner: "acme", repo: "widgets", limit: 5)
  end

  def test_branches_with_runs_is_empty_when_there_are_no_runs
    client = FakeClient.new("/repos/acme/widgets/actions/runs?per_page=100" => { "workflow_runs" => [] })
    source = Owlook::Sources::GitHub.new(client: client)

    assert_equal [], source.branches_with_runs(owner: "acme", repo: "widgets")
  end

  def test_latest_run_returns_nil_when_there_are_no_runs
    client = FakeClient.new(
      "/repos/acme/widgets/actions/runs?branch=quattro&per_page=1" => { "workflow_runs" => [] }
    )
    source = Owlook::Sources::GitHub.new(client: client)

    assert_nil source.latest_run(owner: "acme", repo: "widgets", branch: "quattro")
  end

  # Routes #get(path) to canned responses. Raises loudly on an unexpected
  # path instead of returning nil, so a wrong URL fails the test clearly.
  class FakeClient
    def initialize(routes)
      @routes = routes
    end

    def get(path)
      @routes.fetch(path) { raise KeyError, "no fixture for #{path}" }
    end
  end
end
