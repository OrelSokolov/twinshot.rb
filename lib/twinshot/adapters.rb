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

      # Shared structural comparison (used by html and xml adapters): two
      # canonical line arrays → a result hash. Pass when structures identical.
      def structural_result(kind, a_lines, b_lines)
        return { "kind" => kind, "status" => "pass", "detail" => "structure identical" } if a_lines == b_lines

        changed, entries = line_diff(a_lines, b_lines)
        { "kind" => kind, "status" => "fail", "detail" => "#{changed} structural line(s) differ",
          "diff_lines" => changed, "diff" => entries }
      end

      # Shared canonical DOM serialization: comments dropped, whitespace-only
      # text nodes dropped, runs of whitespace in text squashed to one space,
      # attributes sorted by name. One line per element/text node, indented by
      # depth. downcase_names: true for html (case-insensitive markup),
      # false for xml (case-sensitive).
      def canonical_dom_lines(doc, downcase_names:)
        lines = []
        walk_dom(doc, 0, lines, downcase_names)
        lines
      end

      def walk_dom(node, depth, lines, downcase_names)
        node.children.each do |child|
          case child.type
          when Nokogiri::XML::Node::TEXT_NODE
            text = child.content.gsub(/\s+/, " ").strip
            lines << format("%s%s", "  " * depth, text) unless text.empty?
          when Nokogiri::XML::Node::ELEMENT_NODE
            name = downcase_names ? child.name.downcase : child.name
            attrs = child.attributes.sort_by { |name, _| name }
                         .map { |name, attr| %( #{name}="#{escape_attr(attr.value)}") }.join
            lines << format("%s<%s%s>", "  " * depth, name, attrs)
            walk_dom(child, depth + 1, lines, downcase_names)
          end
        end
      end

      def escape_attr(value)
        value.gsub("&", "&amp;").gsub('"', "&quot;")
      end

      # Shared line diff over two line arrays (used by txt and the structural
      # html/xml adapters).
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
require_relative "adapters/xml"
require_relative "adapters/png"
