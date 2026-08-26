# frozen_string_literal: true

require "test_helper"

class Owlook::Sources::GitHubTest < Minitest::Test
  RUNS_RESPONSE = {
    "workflow_runs" => [
      {
        "id" => 32993198471,
        "status" => "completed",
        "conclusion" => "success",
        "head_branch" => "quattro",
        "head_sha" => "0ae1694830b6bd9511042fe1b89a0062d8c083cb",
        "html_url" => "https://github.com/acme/widgets/actions/runs/32993198471",
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

    assert_equal 32993198471, run[:id]
    assert_equal "completed", run[:status]
    assert_equal "success", run[:conclusion]
    assert_equal "0ae1694830b6bd9511042fe1b89a0062d8c083cb", run[:head_sha]
    assert_equal "https://github.com/acme/widgets/actions/runs/32993198471", run[:html_url]
    assert_equal "2026-08-26T17:19:54Z", run[:updated_at]

    assert_equal 1, run[:jobs].size
    job = run[:jobs].first
    assert_equal "copilot-pull-request-reviewer", job[:name]
    assert_equal "success", job[:conclusion]
    assert_equal 2, job[:steps].size
    assert_equal({ name: "Run tests", number: 2, status: "completed", conclusion: "failure" }, job[:steps][1])
  end

  def test_latest_run_returns_nil_when_there_are_no_runs
    client = FakeClient.new(
      "/repos/acme/widgets/actions/runs?branch=quattro&per_page=1" => { "workflow_runs" => [] }
    )
    source = Owlook::Sources::GitHub.new(client: client)

    assert_nil source.latest_run(owner: "acme", repo: "widgets", branch: "quattro")
  end

  private

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
