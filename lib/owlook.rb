# frozen_string_literal: true

require_relative "owlook/version"
require_relative "owlook/config"
require_relative "owlook/git_repo"
require_relative "owlook/github_client"
require_relative "owlook/sources/github"
require_relative "owlook/sources/kamal"
require_relative "owlook/sources/workflows"
require_relative "owlook/sources/ssh_agent"
require_relative "owlook/sources/queue"
require_relative "owlook/sources/deploy"
require_relative "owlook/observation"
require_relative "owlook/widget_settings"
require_relative "owlook/notifier"
require_relative "owlook/store"
require_relative "owlook/state_writer"
require_relative "owlook/collector"

module Owlook
end
