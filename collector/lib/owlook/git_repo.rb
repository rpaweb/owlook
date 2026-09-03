# frozen_string_literal: true

module Owlook
  # Reads owner/repo and the current branch out of a local git checkout, so
  # the rest of Owlook never has to be told what it can derive itself.
  class GitRepo
    class NoGithubRemoteError < StandardError
      def initialize(path)
        super("No github.com 'origin' remote found in #{path}")
      end
    end

    GITHUB_REMOTE = %r{github\.com[:/]([^/]+)/(.+?)(?:\.git)?\z}

    def initialize(path)
      @path = path
    end

    def owner_and_repo
      match = GITHUB_REMOTE.match(origin_url.to_s)
      raise NoGithubRemoteError, @path unless match

      [match[1], match[2]]
    end

    def current_branch
      run("git", "branch", "--show-current")
    end

    private

    def origin_url
      run("git", "remote", "get-url", "origin")
    end

    def run(*command)
      Dir.chdir(@path) { IO.popen(command, err: File::NULL, &:read).strip }
    end
  end
end
