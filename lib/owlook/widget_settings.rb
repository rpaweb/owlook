# frozen_string_literal: true

require "json"

module Owlook
  # Reads owlook's own widget-settings entry out of Omarchy's shared
  # shell.json — the same file the widget's own gear-icon settings view
  # writes to (via bar.shell.updateEntryInline, see Panel.qml), rather than
  # inventing a second channel between this process and the Quickshell one.
  # A missing file, a missing entry, or unreadable JSON all mean "use the
  # defaults" — a fresh install (or one where the widget was never placed
  # in the bar layout) has no owlook customization in there yet.
  class WidgetSettings
    DEFAULT_PATH = File.expand_path("~/.config/omarchy/shell.json")
    MODULE_ID = "owlook.status"

    def self.load(path: DEFAULT_PATH)
      new(JSON.parse(File.read(path)))
    rescue Errno::ENOENT, JSON::ParserError
      new({})
    end

    def initialize(raw)
      @entry = find_entry(raw)
    end

    # ON: every branch with a recent CI run, dependabot/renovate included.
    # OFF (default): only branches a push-triggered workflow actually runs
    # on — see Sources::Workflows.
    def all_branches?
      !!@entry["allBranches"]
    end

    private

    # Mirrors shell.qml's own updateEntryInline: the entry can live in any
    # of the bar's three layout sections (wherever the user placed the
    # widget) or, if it isn't in the bar layout at all, the top-level
    # "plugins" array.
    def find_entry(raw)
      layout = raw.is_a?(Hash) ? (raw.dig("bar", "layout") || {}) : {}
      sections = %w[left center right].flat_map { |side| Array(layout[side]) }
      plugins = raw.is_a?(Hash) ? Array(raw["plugins"]) : []
      (sections + plugins).find { |e| e.is_a?(Hash) && e["id"] == MODULE_ID } || {}
    end
  end
end
