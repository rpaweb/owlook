# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Owlook::Sources::QueueBackends::SidekiqTest < Minitest::Test
  def test_detect_is_true_when_the_gem_is_in_gemfile_lock
    with_gemfile_lock(<<~LOCK) do |path|
      GEM
        remote: https://rubygems.org/
        specs:
          sidekiq (7.2.0)
            connection_pool (>= 2.3.0)
    LOCK
      assert Owlook::Sources::QueueBackends::Sidekiq.detect?(path)
    end
  end

  # A real false-positive risk this guards against: "sidekiq-cron",
  # "sidekiq-unique-jobs", and similar extension gems all contain
  # "sidekiq" as a substring but aren't Sidekiq itself — matching on the
  # exact "sidekiq (" spec line (Bundler's own lockfile format) rather
  # than a bare substring search avoids picking one of those instead.
  def test_detect_is_false_for_a_sidekiq_extension_gem_without_sidekiq_itself
    with_gemfile_lock(<<~LOCK) do |path|
      GEM
        remote: https://rubygems.org/
        specs:
          sidekiq-cron (1.12.0)
    LOCK
      refute Owlook::Sources::QueueBackends::Sidekiq.detect?(path)
    end
  end

  def test_detect_is_false_without_the_gem
    with_gemfile_lock(<<~LOCK) do |path|
      GEM
        remote: https://rubygems.org/
        specs:
          solid_queue (1.1.0)
    LOCK
      refute Owlook::Sources::QueueBackends::Sidekiq.detect?(path)
    end
  end

  def test_detect_is_false_without_a_gemfile_lock_at_all
    Dir.mktmpdir do |dir|
      refute Owlook::Sources::QueueBackends::Sidekiq.detect?(dir)
    end
  end

  # RUNNER_CODE is never actually executed by this suite (same as Solid
  # Queue's own RUNNER_CODE — there's no live Sidekiq/Rails process to run
  # it against here), so this is the only guard against silently dropping
  # this line: confirmed live, against a real production Rails app
  # (nycbirdalliance), that plain `gem "sidekiq"` does not autoload
  # Sidekiq::Queue/DeadSet/ProcessSet — they raised `uninitialized
  # constant` until this explicit require was added.
  def test_runner_code_requires_sidekiq_api_explicitly
    assert_includes Owlook::Sources::QueueBackends::Sidekiq::RUNNER_CODE, 'require "sidekiq/api"'
  end

  private

  def with_gemfile_lock(content)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), content)
      yield dir
    end
  end
end
