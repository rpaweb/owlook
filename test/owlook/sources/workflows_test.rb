# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class Owlook::Sources::WorkflowsTest < Minitest::Test
  def test_branches_collects_push_triggered_branches_across_workflows
    with_workflow_files(
      "deploy_production.yml" => "on:\n  push:\n    branches:\n      - master\n",
      "deploy_staging.yml" => "on:\n  push:\n    branches:\n      - staging\n"
    ) do |path|
      assert_equal %w[master staging], Owlook::Sources::Workflows.new.branches(path).sort
    end
  end

  # Real-world shape (confirmed against a real project): a PR-validation
  # workflow triggers on `pull_request`, not a named `push` branch — that's
  # exactly what a dependabot/renovate bump also triggers, so a workflow
  # shaped like this must never contribute a branch here, or every bot
  # branch that ever ran would show up as "tracked".
  def test_branches_ignores_a_pull_request_only_workflow
    with_workflow_files(
      "validate_pr.yml" => "on:\n  pull_request:\n"
    ) do |path|
      assert_equal [], Owlook::Sources::Workflows.new.branches(path)
    end
  end

  # workflow_dispatch-only workflows (manual runs) have no `push` key at
  # all — nothing to extract, not an error.
  def test_branches_ignores_a_workflow_with_no_push_trigger
    with_workflow_files(
      "manual.yml" => "on:\n  workflow_dispatch:\n"
    ) do |path|
      assert_equal [], Owlook::Sources::Workflows.new.branches(path)
    end
  end

  def test_branches_dedupes_a_branch_named_in_more_than_one_workflow
    with_workflow_files(
      "a.yml" => "on:\n  push:\n    branches: [master]\n",
      "b.yml" => "on:\n  push:\n    branches: [master]\n"
    ) do |path|
      assert_equal ["master"], Owlook::Sources::Workflows.new.branches(path)
    end
  end

  def test_branches_is_empty_without_a_workflows_directory
    Dir.mktmpdir do |path|
      assert_equal [], Owlook::Sources::Workflows.new.branches(path)
    end
  end

  # A workflow file that isn't valid YAML shouldn't crash the whole scan —
  # skip it and keep reading the others, same tolerance Config gives a
  # briefly-invalid config.yml.
  def test_branches_skips_an_unparseable_workflow_file_and_continues
    with_workflow_files(
      "broken.yml" => "on: [this is not: valid yaml\n",
      "deploy.yml" => "on:\n  push:\n    branches: [master]\n"
    ) do |path|
      assert_equal ["master"], Owlook::Sources::Workflows.new.branches(path)
    end
  end

  private

  def with_workflow_files(files)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".github", "workflows"))
      files.each { |name, content| File.write(File.join(dir, ".github", "workflows", name), content) }
      yield dir
    end
  end
end
