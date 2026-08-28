# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class Owlook::GitRepoTest < Minitest::Test
  def test_owner_and_repo_from_an_https_remote
    with_repo(remote: "https://github.com/exampleapp/exampleapp.git") do |path|
      assert_equal ["exampleapp", "exampleapp"], Owlook::GitRepo.new(path).owner_and_repo
    end
  end

  def test_owner_and_repo_from_an_ssh_remote
    with_repo(remote: "git@github.com:acme/widgets.git") do |path|
      assert_equal ["acme", "widgets"], Owlook::GitRepo.new(path).owner_and_repo
    end
  end

  def test_owner_and_repo_raises_without_a_github_remote
    with_repo(remote: nil) do |path|
      assert_raises(Owlook::GitRepo::NoGithubRemoteError) do
        Owlook::GitRepo.new(path).owner_and_repo
      end
    end
  end

  def test_current_branch_returns_the_checked_out_branch
    with_repo(remote: "https://github.com/acme/widgets.git", branch: "feature-x") do |path|
      assert_equal "feature-x", Owlook::GitRepo.new(path).current_branch
    end
  end

  private

  def with_repo(remote:, branch: "main")
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        system("git", "init", "-q", "-b", branch)
        system("git", "config", "user.email", "test@example.com")
        system("git", "config", "user.name", "Test")
        File.write("README.md", "hi")
        system("git", "add", "README.md")
        system("git", "commit", "-q", "-m", "init")
        system("git", "remote", "add", "origin", remote) if remote
      end
      yield dir
    end
  end
end
