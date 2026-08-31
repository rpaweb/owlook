# frozen_string_literal: true

require "test_helper"

class Owlook::NotifierTest < Minitest::Test
  def test_notify_runs_omarchy_notification_send_with_the_expected_arguments
    calls = []
    notifier = Owlook::Notifier.new(runner: ->(*args) { calls << args })

    notifier.notify("Owlook — acme/widgets", "CI main: failure", urgency: "critical")

    assert_equal 1, calls.size
    args = calls.first
    assert_equal "omarchy-notification-send", args[0]
    assert_equal "Owlook — acme/widgets", args[1]
    assert_equal "CI main: failure", args[2]
    assert_includes args, "critical"
    assert_includes args, "--app-name"
    assert_includes args, "Owlook"
  end

  def test_notify_passes_the_owlook_icon_as_an_image_not_a_glyph
    calls = []
    notifier = Owlook::Notifier.new(runner: ->(*args) { calls << args })

    notifier.notify("headline", "description")

    args = calls.first
    refute_includes args, "-g", "glyph-based icon dropped in favor of the real mark"
    image_index = args.index("--image")
    refute_nil image_index, "expected --image to be passed"
    icon_path = args[image_index + 1]
    assert File.exist?(icon_path), "expected #{icon_path} to exist"
    assert_equal ".png", File.extname(icon_path)
  end

  def test_notify_defaults_to_normal_urgency
    calls = []
    notifier = Owlook::Notifier.new(runner: ->(*args) { calls << args })

    notifier.notify("headline", "description")

    assert_includes calls.first, "normal"
  end

  def test_command_is_configurable
    calls = []
    notifier = Owlook::Notifier.new(command: "/custom/path/notify", runner: ->(*args) { calls << args })

    notifier.notify("headline", "description")

    assert_equal "/custom/path/notify", calls.first[0]
  end
end
