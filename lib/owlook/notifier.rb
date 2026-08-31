# frozen_string_literal: true

module Owlook
  # Sends a desktop notification via Omarchy's own omarchy-notification-send
  # — never a raw `notify-send`, so a change to how Omarchy tags/styles its
  # notifications (the -a app_name convention that lets a toast through DND,
  # see the script's own comment) is picked up for free. `runner` is
  # injectable (real default: Kernel#system, array-form so nothing here ever
  # touches a shell) purely so tests never actually pop a notification.
  class Notifier
    DEFAULT_RUNNER = ->(*args) { system(*args, out: File::NULL, err: File::NULL) }

    # The approved mark, shipped with the gem (see assets/owlook-icon.png).
    # `-g` only takes a single text/emoji glyph — it can't render our SVG
    # mark, so this goes through `--image` (a real path/URI hint) instead.
    ICON_PATH = File.expand_path("../../assets/owlook-icon.png", __dir__)

    def initialize(command: "omarchy-notification-send", runner: DEFAULT_RUNNER)
      @command = command
      @runner = runner
    end

    def notify(headline, description, urgency: "normal")
      @runner.call(@command, headline, description, "--app-name", "Owlook", "-u", urgency, "--image", ICON_PATH)
    end
  end
end
