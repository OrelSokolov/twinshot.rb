# frozen_string_literal: true

require "diff/lcs"

module Twinshot
  # Per-format comparison strategies. An adapter is registered for a set of
  # extensions and responds to .call(rel, oracle_file, current_file, ctx),
  # returning a result hash (string keys — results travel through JSON in
  # worker processes):
  #
  #   { "kind" => "png", "status" => "pass"|"fail", "detail" => "...",
  #     "image" => true|nil, ...format-specific keys }
  #
  # ctx carries max_diff_ratio and report_dir.
  module Adapters
    Ctx = Struct.new(:max_diff_ratio, :report_dir, keyword_init: true)

    @registry = {}
    class << self
      attr_reader :registry

      def register(adapter, *extensions)
        extensions.each { |ext| @registry[ext.to_s.downcase] = adapter }
      end

      # nil means "no adapter" — an unknown file is a failure by design.
      def for(filename)
        @registry[File.extname(filename).delete_prefix(".").downcase]
      end

      # Shared line diff over two line arrays (used by txt and html adapters).
      # Returns [changed_line_count, [ { "t" => "same"|"del"|"add", "text" }, ... ]].
      def line_diff(a_lines, b_lines, cap: 400)
        changed = 0
        entries = []
        Diff::LCS.sdiff(a_lines, b_lines).each do |op|
          case op.action
          when "="
            entries << { "t" => "same", "text" => op.old_element }
          when "-"
            changed += 1
            entries << { "t" => "del", "text" => op.old_element }
          when "+"
            changed += 1
            entries << { "t" => "add", "text" => op.new_element }
          when "!"
            changed += 2
            entries << { "t" => "del", "text" => op.old_element }
            entries << { "t" => "add", "text" => op.new_element }
          end
        end
        entries << { "t" => "same", "text" => "… (diff truncated)" } if entries.size > cap
        [changed, entries.first(cap)]
      end
    end
  end
end

require_relative "adapters/binary"
require_relative "adapters/txt"
require_relative "adapters/html"
require_relative "adapters/png"
