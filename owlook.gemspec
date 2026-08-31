# frozen_string_literal: true

require_relative "lib/owlook/version"

Gem::Specification.new do |spec|
  spec.name = "owlook"
  spec.version = Owlook::VERSION
  spec.authors = ["Rafael Peña-Azar"]
  spec.summary = "CI, deploy, and queue health for Rails apps, in the Omarchy bar."
  spec.description = <<~DESC
    A single collector process watches GitHub Actions runs, Kamal deploy
    destinations, and background job queues for your Rails projects, and
    surfaces their status as a bar widget in Omarchy (Quattro).
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.homepage = "https://github.com/rpaweb/owlook"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "bin/*", "shell/**/*", "assets/**/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.bindir = "bin"
  spec.executables = Dir["bin/*"].map { |f| File.basename(f) }

  spec.add_dependency "kamal", ">= 2.0"
end
