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

    def initialize(command: "omarchy-notification-send", runner: DEFAULT_RUNNER)
      @command = command
      @runner = runner
    end

    def notify(headline, description, urgency: "normal")
      @runner.call(@command, headline, description, "--app-name", "Owlook", "-u", urgency, "-g", "🦉")
    end
  end
end
