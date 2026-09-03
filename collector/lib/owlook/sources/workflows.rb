# frozen_string_literal: true

require "yaml"

module Owlook
  module Sources
    # Reads which branches actually have CI wired to them, straight from the
    # project's own .github/workflows/*.yml — filesystem only, no GitHub API
    # call, the same reason Sources::Kamal reads config/deploy*.yml locally
    # instead of asking Kamal. A branch counts if some workflow triggers on
    # `push` to it by name — that's how a deploy workflow is wired (push to
    # master -> deploy to production), so it's a real signal that the branch
    # is tied to an environment, not just "GitHub has a run for it somewhere
    # in its history". A workflow that only triggers on `pull_request`
    # (dependabot bumps, feature-branch validation) never adds anything
    # here — confirmed against a real repo that this is exactly what keeps
    # a handful of long-lived branches (master, staging) from being buried
    # under a dozen dependabot branches that also happen to have runs.
    class Workflows
      def branches(project_path)
        workflow_files(project_path).flat_map { |file| push_branches(file) }.uniq
      end

      private

      def workflow_files(project_path)
        Dir.glob(File.join(project_path, ".github", "workflows", "*.{yml,yaml}"))
      end

      def push_branches(file)
        raw = YAML.safe_load_file(file)
        return [] unless raw.is_a?(Hash)

        # YAML 1.1 parses a bare `on:` mapping key as the boolean `true`,
        # not the string "on" — a well-known GitHub Actions authoring
        # gotcha (confirmed against Ruby's own Psych parser: raw["on"] is
        # nil, raw[true] has the real value).
        on = raw["on"] || raw[true]
        return [] unless on.is_a?(Hash)

        push = on["push"]
        return [] unless push.is_a?(Hash)

        Array(push["branches"])
      rescue Psych::SyntaxError
        []
      end
    end
  end
end
