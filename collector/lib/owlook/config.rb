# frozen_string_literal: true

require "yaml"
require "fileutils"

module Owlook
  class Config
    class InvalidFileError < StandardError
      def initialize(path, cause)
        super("Owlook config file is not valid YAML: #{path} (#{cause.message})")
      end
    end

    # Written on first run when nothing exists at the configured path yet
    # — a real user reported installing the plugin with no guidance on
    # what to put in this file, and the collector crashing outright (see
    # .load's own comment) rather than showing anything helpful. `projects`
    # ships commented out and empty rather than pre-filled with a fake
    # example path, which would either be wrong (not a real checkout) or,
    # worse, silently "work" by resolving to some unrelated real directory.
    DEFAULT_TEMPLATE = <<~YAML
      # Owlook tracks projects by their local git checkout path — one entry
      # per project, each an absolute or ~-relative path to a repo you
      # already have cloned. Owner/repo, branches, and Kamal destinations
      # are all derived from that checkout; nothing else to configure here.
      #
      # projects:
      #   - ~/Work/oss/exampleapp
      #   - ~/Work/oss/another-project
      #
      # Add or remove entries anytime — picked up on the next poll, no
      # restart needed.

      projects: []
    YAML

    attr_reader :projects

    # A missing file is written with DEFAULT_TEMPLATE rather than raised
    # as an error — the previous behavior crashed the collector's very
    # first log line on a completely ordinary first run (nothing has
    # created this file yet right after `omarchy plugin add`), with no
    # indication anywhere of what the user was even supposed to create.
    def self.load(path)
      write_default(path) unless File.exist?(path)

      begin
        raw = YAML.safe_load_file(path) || {}
      rescue Psych::SyntaxError => e
        raise InvalidFileError.new(path, e)
      end

      new(raw)
    end

    def self.write_default(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, DEFAULT_TEMPLATE)
    end
    private_class_method :write_default

    def initialize(raw)
      @projects = Array(raw["projects"]).map { |path| File.expand_path(path) }
    end
  end
end
