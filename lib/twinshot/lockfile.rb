# frozen_string_literal: true

require "fileutils"

module Twinshot
  # One run at a time per project: while a command works on a config's
  # trees, tmp/twinshot.pid in the config's directory holds the running
  # pid. A second run refuses to start with a clear error; a pid file
  # left behind by a crashed run is never removed automatically — it is
  # reported so the user can remove it by hand.
  class Lockfile
    class Error < StandardError; end

    # Where the lock lives, relative to the config's directory.
    RELATIVE_PATH = File.join("tmp", "twinshot.pid").freeze

    # Runs the block under the lock: acquires first, releases after —
    # also on failure. Raises Error before the block starts when another
    # run holds the lock or a stale pid file is in the way.
    def self.under(config)
      lock = new(File.join(config.root, RELATIVE_PATH))
      lock.acquire
      begin
        yield
      ensure
        lock.release
      end
    end

    def initialize(path)
      @path = path
      @held = false
    end

    # Creates the pid file atomically (O_EXCL), so two runs starting at
    # the same moment can't both win; the loser gets the "already
    # running" error from the winner's pid.
    def acquire
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::CREAT | File::EXCL | File::WRONLY) { |f| f.write(Process.pid.to_s) }
      @held = true
    rescue Errno::EEXIST
      raise Error, taken_message if File.exist?(@path)

      retry # vanished between EEXIST and the check — try to take it again
    end

    # Removes the pid file. Only the run that created it releases, and a
    # file already gone (a stray `rm`, say) is fine.
    def release
      return unless @held

      File.delete(@path)
    rescue Errno::ENOENT
      nil
    ensure
      @held = false
    end

    private

    # The error when the pid file is already there: a live pid means
    # another run is active; a dead or unreadable pid means a leftover
    # from a crashed run — the user removes it manually.
    def taken_message
      pid = Integer(File.read(@path).strip, 10)
      raise ArgumentError if pid <= 0 # a real process pid is always positive

      if alive?(pid)
        "another twinshot run is already active (pid #{pid}, see #{RELATIVE_PATH}) — wait for it to finish"
      else
        "#{RELATIVE_PATH} holds pid #{pid}, but that process is not running — " \
          "it may be left over from a crashed run; remove #{RELATIVE_PATH} manually and try again"
      end
    rescue Errno::ENOENT, ArgumentError
      "#{RELATIVE_PATH} exists but holds no readable pid — " \
        "it may be left over from a crashed run; remove #{RELATIVE_PATH} manually and try again"
    end

    # Signal 0 is the existence probe, and it is cross-platform: POSIX
    # sends nothing and just checks, while Ruby's Windows build maps it
    # onto OpenProcess. EPERM (Unix) and EACCES (Windows) mean the
    # process is there but not ours; ESRCH — on both — means the pid is
    # gone. One caveat: on Windows a child that exited but was not
    # reaped can still answer (like a Unix zombie); that only makes the
    # check err on the safe side — the error tells the user to wait.
    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::EPERM, Errno::EACCES
      true
    rescue Errno::ESRCH
      false
    end
  end
end
