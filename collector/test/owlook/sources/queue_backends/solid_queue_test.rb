# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::Sources::QueueBackends::SolidQueueTest < Minitest::Test
  def test_detect_is_true_when_the_gem_is_in_gemfile_lock
    with_gemfile_lock(<<~LOCK) do |path|
      GEM
        remote: https://rubygems.org/
        specs:
          solid_queue (1.1.0)
            activejob (>= 7.1)
    LOCK
      assert Owlook::Sources::QueueBackends::SolidQueue.detect?(path)
    end
  end

  def test_detect_is_false_without_the_gem
    with_gemfile_lock(<<~LOCK) do |path|
      GEM
        remote: https://rubygems.org/
        specs:
          sidekiq (7.2.0)
    LOCK
      refute Owlook::Sources::QueueBackends::SolidQueue.detect?(path)
    end
  end

  def test_detect_is_false_without_a_gemfile_lock_at_all
    Dir.mktmpdir do |dir|
      refute Owlook::Sources::QueueBackends::SolidQueue.detect?(dir)
    end
  end

  private

  def with_gemfile_lock(content)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), content)
      yield dir
    end
  end
end
