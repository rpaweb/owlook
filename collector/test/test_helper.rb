# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "owlook"
require "minitest/autorun"

# Owlook::Collector's constructor default (settings_loader: -> {
# WidgetSettings.load }) reads whoever's real ~/.config/omarchy/shell.json
# happens to be on the machine running the tests, unless a test explicitly
# overrides it — and most of this suite's Owlook::Collector.new calls don't
# (audited: 24 of 27 construction sites). That's fine on a CI runner with
# no such file (defaults to all_branches: false), but on a real dev
# machine it silently leaks whatever the widget's live "all branches"
# toggle is set to into otherwise-hermetic tests — a real bug this project
# hit: toggling it on to verify a live fix broke an unrelated concurrency
# test locally (SlowGithubSource has no branches_with_runs, needed only in
# broad mode) with no code change at fault. Redirecting the constant here,
# once, for the whole suite, is simpler and more durable than auditing
# every call site — WidgetSettings.load already treats a missing file as
# "use the defaults" (see its own comment), so this path only ever needs
# to not exist.
Owlook::WidgetSettings.send(:remove_const, :DEFAULT_PATH)
Owlook::WidgetSettings.const_set(:DEFAULT_PATH, "/nonexistent/owlook-test-must-not-read-a-real-shell-json")
