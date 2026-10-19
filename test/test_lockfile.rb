# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class TestLockfile < Minitest::Test
  def test_under_creates_and_removes_the_pid_file
    Dir.mktmpdir do |tmp|
      config = fake_config(tmp)
      Twinshot::Lockfile.under(config) do
        assert_equal Process.pid.to_s, File.read(File.join(tmp, "tmp", "twinshot.pid"))
      end
      refute File.exist?(File.join(tmp, "tmp", "twinshot.pid"))
    end
  end

  def test_under_releases_on_failure
    Dir.mktmpdir do |tmp|
      assert_raises(RuntimeError) { Twinshot::Lockfile.under(fake_config(tmp)) { raise "boom" } }
      refute File.exist?(File.join(tmp, "tmp", "twinshot.pid"))
    end
  end

  def test_live_pid_is_refused
    Dir.mktmpdir do |tmp|
      write_lock(tmp, Process.pid) # our own pid is definitely alive
      error = assert_raises(Twinshot::Lockfile::Error) { Twinshot::Lockfile.under(fake_config(tmp)) {} }
      assert_includes error.message, "already active (pid #{Process.pid},"
      assert_equal Process.pid.to_s, File.read(File.join(tmp, "tmp", "twinshot.pid"))
    end
  end

  def test_dead_pid_is_reported_as_leftover
    Dir.mktmpdir do |tmp|
      write_lock(tmp, dead_pid)
      error = assert_raises(Twinshot::Lockfile::Error) { Twinshot::Lockfile.under(fake_config(tmp)) {} }
      assert_includes error.message, "that process is not running"
      assert_includes error.message, "remove tmp/twinshot.pid manually"
    end
  end

  def test_unreadable_pid_is_reported_as_leftover
    Dir.mktmpdir do |tmp|
      write_lock(tmp, "not a pid")
      error = assert_raises(Twinshot::Lockfile::Error) { Twinshot::Lockfile.under(fake_config(tmp)) {} }
      assert_includes error.message, "no readable pid"
    end
  end

  def test_nonpositive_pid_is_reported_as_leftover
    Dir.mktmpdir do |tmp|
      write_lock(tmp, 0) # kill(0, 0) would target the process group, not a process
      error = assert_raises(Twinshot::Lockfile::Error) { Twinshot::Lockfile.under(fake_config(tmp)) {} }
      assert_includes error.message, "no readable pid"
    end
  end

  def test_cli_compare_refuses_while_locked
    Dir.mktmpdir do |tmp|
      make_trees(tmp)
      fake_config(tmp)
      write_lock(tmp, Process.pid)
      exit_code = run_cli("-c", File.join(tmp, "twinshot.yml"), "compare")
      assert_equal 2, exit_code
      assert_includes @err.string, "twinshot: another twinshot run is already active"
      assert File.exist?(File.join(tmp, "tmp", "twinshot.pid"))
    end
  end

  def test_cli_compare_removes_the_pid_file_after_the_run
    Dir.mktmpdir do |tmp|
      make_trees(tmp)
      fake_config(tmp)
      assert_equal 0, run_cli("-c", File.join(tmp, "twinshot.yml"), "compare")
      refute File.exist?(File.join(tmp, "tmp", "twinshot.pid"))
    end
  end

  private

  # The config's directory is what the lock is keyed to; a real Config is
  # loaded from disk, so a minimal twinshot.yml does the job.
  def fake_config(dir)
    path = File.join(dir, "twinshot.yml")
    File.write(path, <<~YAML)
      oracle: {path: #{dir}/oracle}
      current: {path: #{dir}/current}
    YAML
    Twinshot::Config.load(path)
  end

  def write_lock(tmp, pid)
    lock = File.join(tmp, "tmp", "twinshot.pid")
    FileUtils.mkdir_p(File.dirname(lock))
    File.write(lock, pid.to_s)
    lock
  end

  # A pid that was alive and is gone now: spawn a process, wait for it.
  def dead_pid
    pid = spawn("sleep", "0.01")
    Process.wait(pid)
    pid
  end

  def make_trees(tmp)
    %w[oracle current].each do |side|
      dir = File.join(tmp, side)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "page.txt"), "same\n")
    end
  end

  def run_cli(*args)
    @out = StringIO.new
    @err = StringIO.new
    Twinshot::CLI.new(args, out: @out, err: @err).call
  end
end
