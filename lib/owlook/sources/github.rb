# frozen_string_literal: true

module Owlook
  module Sources
    # Given owner/repo/branch, returns the latest workflow run with its jobs
    # and steps. `client` only needs to respond to #get(path) -> Hash; the
    # real transport is Owlook::GithubClient, but tests inject a fake one.
    class GitHub
      def initialize(client:)
        @client = client
      end

      # Every distinct branch with a run in the most recent `limit` — no
      # jobs, no per-branch call, just enough to answer "what's been
      # running CI lately" in one request. This is the "all branches"
      # mode's data source (see Owlook::WidgetSettings#all_branches?):
      # unlike Sources::Workflows, it doesn't care whether a branch is
      # wired to a deploy — a dependabot branch that merely triggered a
      # pull_request-shaped workflow shows up here too, which is exactly
      # the point when the user has opted into seeing it.
      def branches_with_runs(owner:, repo:, limit: 100)
        runs = @client.get("/repos/#{owner}/#{repo}/actions/runs?per_page=#{limit}").fetch("workflow_runs")
        runs.map { |run| run["head_branch"] }.compact.uniq
      end

      def latest_run(owner:, repo:, branch:)
        run = @client.get("/repos/#{owner}/#{repo}/actions/runs?branch=#{branch}&per_page=1")
                     .fetch("workflow_runs").first
        return nil unless run

        jobs = @client.get("/repos/#{owner}/#{repo}/actions/runs/#{run.fetch('id')}/jobs").fetch("jobs")

        {
          id: run.fetch("id"),
          status: run.fetch("status"),
          conclusion: run["conclusion"],
          head_sha: run.fetch("head_sha"),
          html_url: run.fetch("html_url"),
          updated_at: run.fetch("updated_at"),
          actor: run.dig("triggering_actor", "login") || run.dig("actor", "login"),
          jobs: jobs.map { |job| parse_job(job) }
        }
      end

      private

      def parse_job(job)
        {
          name: job.fetch("name"),
          status: job.fetch("status"),
          conclusion: job["conclusion"],
          steps: job.fetch("steps").map { |step| parse_step(step) }
        }
      end

      def parse_step(step)
        {
          name: step.fetch("name"),
          number: step.fetch("number"),
          status: step.fetch("status"),
          conclusion: step["conclusion"]
        }
      end
    end
  end
end
