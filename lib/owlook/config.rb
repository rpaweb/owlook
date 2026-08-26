# frozen_string_literal: true

require "yaml"

module Owlook
  class Config
    class MissingFileError < StandardError
      def initialize(path)
        super("Owlook config file not found: #{path}")
      end
    end

    class InvalidFileError < StandardError
      def initialize(path, cause)
        super("Owlook config file is not valid YAML: #{path} (#{cause.message})")
      end
    end

    attr_reader :projects

    def self.load(path)
      raise MissingFileError, path unless File.exist?(path)

      begin
        raw = YAML.safe_load_file(path) || {}
      rescue Psych::SyntaxError => e
        raise InvalidFileError.new(path, e)
      end

      new(raw)
    end

    def initialize(raw)
      @projects = Array(raw["projects"]).map { |path| File.expand_path(path) }
    end
  end
end
