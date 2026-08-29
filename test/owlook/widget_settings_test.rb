# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "json"

class Owlook::WidgetSettingsTest < Minitest::Test
  def test_all_branches_is_false_by_default
    with_shell_json({}) do |path|
      refute Owlook::WidgetSettings.load(path: path).all_branches?
    end
  end

  def test_all_branches_reads_true_from_the_bar_layout
    shell_json = { "bar" => { "layout" => { "right" => [
      { "id" => "owlook.status", "allBranches" => true }
    ] } } }
    with_shell_json(shell_json) do |path|
      assert Owlook::WidgetSettings.load(path: path).all_branches?
    end
  end

  # updateEntryInline (shell.qml) checks every layout section, not just
  # one — the widget could be in left/center/right depending on how the
  # user arranged their bar.
  def test_all_branches_finds_the_entry_in_any_layout_section
    %w[left center right].each do |side|
      shell_json = { "bar" => { "layout" => { side => [
        { "id" => "owlook.status", "allBranches" => true }
      ] } } }
      with_shell_json(shell_json) do |path|
        assert Owlook::WidgetSettings.load(path: path).all_branches?, "expected to find the entry under #{side}"
      end
    end
  end

  # updateEntryInline also falls back to a top-level "plugins" entry when
  # the widget isn't in the bar layout at all.
  def test_all_branches_finds_the_entry_in_top_level_plugins
    shell_json = { "plugins" => [{ "id" => "owlook.status", "allBranches" => true }] }
    with_shell_json(shell_json) do |path|
      assert Owlook::WidgetSettings.load(path: path).all_branches?
    end
  end

  def test_all_branches_ignores_a_different_widgets_entry
    shell_json = { "bar" => { "layout" => { "right" => [
      { "id" => "omarchy.clock", "allBranches" => true }
    ] } } }
    with_shell_json(shell_json) do |path|
      refute Owlook::WidgetSettings.load(path: path).all_branches?
    end
  end

  def test_load_defaults_when_the_file_does_not_exist
    refute Owlook::WidgetSettings.load(path: "/nonexistent/shell.json").all_branches?
  end

  def test_load_defaults_when_the_file_is_not_valid_json
    Dir.mktmpdir do |dir|
      path = File.join(dir, "shell.json")
      File.write(path, "{not valid json")
      refute Owlook::WidgetSettings.load(path: path).all_branches?
    end
  end

  private

  def with_shell_json(hash)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "shell.json")
      File.write(path, JSON.generate(hash))
      yield path
    end
  end
end
