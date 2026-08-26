# frozen_string_literal: true

require "json"

module Owlook
  # Writes a Store snapshot to disk atomically (tmp file + rename), and only
  # when the content actually changed — so the widget's FileView watcher
  # never fires for a no-op poll.
  class StateWriter
    def initialize(path)
      @path = path
      @tmp_path = "#{path}.tmp"
    end

    def write(snapshot)
      json = JSON.generate(snapshot)
      return false if File.exist?(@path) && File.read(@path) == json

      File.write(@tmp_path, json)
      File.rename(@tmp_path, @path)
      true
    end
  end
end
