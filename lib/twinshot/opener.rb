# frozen_string_literal: true

require "rbconfig"

module Twinshot
  # Cross-platform port of macOS `open`: launch the default browser with a
  # local file (the report). One adapter per OS family — Darwin (`open`),
  # Windows (`start` via cmd.exe), Linux (`xdg-open`) — selected by
  # RbConfig's host_os. The registry mirrors the format-adapters one.
  module Opener
    class Error < StandardError; end

    @adapters = {}
    class << self
      attr_reader :adapters

      def register(key, adapter)
        @adapters[key.to_s] = adapter
      end

      # host_os (RbConfig::CONFIG["host_os"]) normalized to the adapter key.
      def platform_for(host_os)
        case host_os.to_s
        when /darwin|macintosh/ then "darwin"
        when /mswin|mingw|cygwin|bccwin|wince|emx|msys|windows/ then "windows"
        else "linux"
        end
      end

      def for_platform(host_os)
        adapters.fetch(platform_for(host_os)) do
          raise Error, "no opener adapter for platform #{host_os.inspect}"
        end
      end

      # Adapter for the running Ruby build.
      def current
        for_platform(RbConfig::CONFIG["host_os"])
      end

      # Expand and open a local file in the default browser. Raises Error
      # (nothing thrown at the caller's exit code by itself).
      def open(path)
        current.open(File.expand_path(path))
      end

      # Spawn helper shared by the adapters; stdout/stderr suppressed (openers
      # chatter). Returns the system() truth value — false/nil means the
      # command is missing or refused to run. Stubbed in tests.
      def launch(*args)
        system(*args, out: File::NULL, err: File::NULL)
      end
    end
  end
end

require_relative "opener/darwin"
require_relative "opener/windows"
require_relative "opener/linux"
