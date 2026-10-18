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
        Adapters.structural_result("html", canonical_lines(oracle_file), canonical_lines(current_file))
      end

      def canonical_lines(path)
        doc = Nokogiri::HTML4(File.read(path, encoding: "UTF-8"))
        Adapters.canonical_dom_lines(doc, downcase_names: true)
      end
    end

    register(Html, "html", "htm")
  end
end
