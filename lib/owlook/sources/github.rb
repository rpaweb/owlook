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

      def latest_run(owner:, repo:, branch:)
        run = @client.get("/repos/#{owner}/#{repo}/actions/runs?branch=#{branch}&per_page=1")
          .fetch("workflow_runs").first
        return nil unless run

        jobs = @client.get("/repos/#{owner}/#{repo}/actions/runs/#{run.fetch("id")}/jobs").fetch("jobs")

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
