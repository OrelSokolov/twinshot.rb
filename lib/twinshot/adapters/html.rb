# frozen_string_literal: true

require "nokogiri"

module Twinshot
  # Adapter implementations (the contract lives in adapters.rb).
  module Adapters
    # HTML compares by DOM structure, not raw text: canonical serialization
    # (comments dropped, whitespace-only text nodes dropped, runs of whitespace
    # in text squashed to one space, attributes sorted by name) followed by a
    # line diff over that canonical form. Pass when structures are identical.
    module Html
      module_function

      def call(_rel, oracle_file, current_file, _ctx)
        a_lines = canonical_lines(oracle_file)
        b_lines = canonical_lines(current_file)
        return { "kind" => "html", "status" => "pass", "detail" => "structure identical" } if a_lines == b_lines

        changed, entries = Adapters.line_diff(a_lines, b_lines)
        { "kind" => "html", "status" => "fail", "detail" => "#{changed} structural line(s) differ",
          "diff_lines" => changed, "diff" => entries }
      end

      def canonical_lines(path)
        doc = Nokogiri::HTML4(File.read(path, encoding: "UTF-8"))
        lines = []
        walk(doc, 0, lines)
        lines
      end

      def walk(node, depth, lines)
        node.children.each do |child|
          case child.type
          when Nokogiri::XML::Node::TEXT_NODE
            text = child.content.gsub(/\s+/, " ").strip
            lines << format("%s%s", "  " * depth, text) unless text.empty?
          when Nokogiri::XML::Node::ELEMENT_NODE
            attrs = child.attributes.sort_by { |name, _| name }
                         .map { |name, attr| %( #{name}="#{escape_attr(attr.value)}") }.join
            lines << format("%s<%s%s>", "  " * depth, child.name.downcase, attrs)
            walk(child, depth + 1, lines)
          end
        end
      end

      def escape_attr(value)
        value.gsub("&", "&amp;").gsub('"', "&quot;")
      end
    end

    register(Html, "html", "htm")
  end
end
