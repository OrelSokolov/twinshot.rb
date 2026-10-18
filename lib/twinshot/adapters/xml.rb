# frozen_string_literal: true

require "nokogiri"

module Twinshot
  # Adapter implementations (the contract lives in adapters.rb).
  module Adapters
    # XML compares by structure like html, but through the XML parser:
    # element names stay case-sensitive and no html/body structure is
    # implied. Canonical serialization → line diff; pass when structures are
    # identical. svg is XML, so it lands here too (compared as markup, not
    # rendered pixels).
    module Xml
      module_function

      def call(_rel, oracle_file, current_file, _ctx)
        Adapters.structural_result("xml", canonical_lines(oracle_file), canonical_lines(current_file))
      end

      def canonical_lines(path)
        doc = Nokogiri::XML(File.read(path, encoding: "UTF-8"))
        Adapters.canonical_dom_lines(doc, downcase_names: false)
      end
    end

    register(Xml, "xml", "svg")
  end
end
