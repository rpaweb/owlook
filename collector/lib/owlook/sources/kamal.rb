# frozen_string_literal: true

require "yaml"

module Owlook
  module Sources
    # Enumerates a project's Kamal destinations from its config/deploy*.yml
    # files. No SSH, no `Kamal::Configuration` — just enough YAML reading to
    # know which destinations actually exist.
    class Kamal
      def destinations(project_path)
        base = File.join(project_path, "config", "deploy.yml")
        return [] unless File.exist?(base)

        named = Dir.glob(File.join(project_path, "config", "deploy.*.yml")).map do |file|
          File.basename(file, ".yml").sub(/\Adeploy\./, "")
        end

        servers?(base) ? ["default"] + named : named
      end

      private

      # A base deploy.yml with no `servers:` of its own is a shared template
      # (registry, builder, env defaults) meant to be merged with a named
      # destination, never deployed alone — confirmed against a real project
      # where reporting "default" for it would have been a destination
      # nothing could ever answer for.
      def servers?(deploy_yml_path)
        config = YAML.safe_load_file(deploy_yml_path, aliases: true) || {}
        !!config["servers"]
      rescue Psych::SyntaxError
        false
      end
    end
  end
end
