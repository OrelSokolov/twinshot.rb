# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestOpener < Minitest::Test
  def test_platform_mapping_darwin_and_windows
    assert_equal "darwin", Twinshot::Opener.platform_for("darwin20.6.0")
    assert_equal "darwin", Twinshot::Opener.platform_for("macintosh12")
    assert_equal "windows", Twinshot::Opener.platform_for("mswin32")
    assert_equal "windows", Twinshot::Opener.platform_for("mingw32")
    assert_equal "windows", Twinshot::Opener.platform_for("cygwin")
    assert_equal "windows", Twinshot::Opener.platform_for("msys")
  end

  def test_platform_mapping_linux_and_fallback
    assert_equal "linux", Twinshot::Opener.platform_for("linux-gnu")
    assert_equal "linux", Twinshot::Opener.platform_for("freebsd15")
    assert_equal "linux", Twinshot::Opener.platform_for("whatever-else")
  end

  def test_registry_covers_all_platforms
    %w[darwin windows linux].each do |key|
      assert Twinshot::Opener.adapters[key], key
      assert_respond_to Twinshot::Opener.adapters[key], :open, key
    end
  end

  def test_current_matches_running_ruby
    host_os = RbConfig::CONFIG["host_os"]
    assert_equal Twinshot::Opener.adapters[Twinshot::Opener.platform_for(host_os)],
                 Twinshot::Opener.current
  end

  def test_darwin_uses_open
    launched = capture_launch { Twinshot::Opener::Darwin.open("/r/report.html") }
    assert_equal ["open", "/r/report.html"], launched
  end

  def test_windows_uses_cmd_start_with_empty_title
    launched = capture_launch { Twinshot::Opener::Windows.open("/r/report.html") }
    assert_equal ["cmd", "/c", "start", "", "/r/report.html"], launched
  end

  def test_linux_uses_xdg_open
    launched = capture_launch { Twinshot::Opener::Linux.open("/r/report.html") }
    assert_equal ["xdg-open", "/r/report.html"], launched
  end

  def test_launch_failure_raises_with_command_hint
    Twinshot::Opener.stub(:launch, nil) do
      error = assert_raises(Twinshot::Opener::Error) { Twinshot::Opener::Linux.open("/r/report.html") }
      assert_includes error.message, "xdg-open"
    end
  end

  def test_open_expands_path_and_dispatches_to_current_adapter
    launched = nil
    Dir.mktmpdir do |tmp|
      launched = capture_launch { Twinshot::Opener.open(File.join(tmp, "report.html")) }
    end
    assert_equal 2, launched.length
    assert_match(%r{/report\.html\z}, launched.last)
  end

  private

  def capture_launch(&block)
    launched = nil
    recorder = lambda do |*args|
      launched = args
      true
    end
    Twinshot::Opener.stub(:launch, recorder, &block)
    launched
  end
end
