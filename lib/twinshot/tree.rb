# frozen_string_literal: true

require "find"

module Twinshot
  # Directory tree scanning and 1:1 structure comparison.
  module Tree
    module_function

    # Sorted relative paths of all files under root (hidden files included).
    def files(root)
      prefix = "#{root.chomp("/")}/"
      [].tap do |out|
        Find.find(root) do |path|
          out << path.delete_prefix(prefix) if path != root && File.file?(path)
        end
      end.sort
    end

    # Files present in only one of the trees:
    # { "missing" => [in oracle, absent in current], "extra" => [in current, absent in oracle] }.
    def diff(oracle_files, current_files)
      oracle_set = oracle_files.to_h { |rel| [rel, true] }
      current_set = current_files.to_h { |rel| [rel, true] }
      {
        "missing" => oracle_files.reject { current_set.key?(_1) },
        "extra" => current_files.reject { oracle_set.key?(_1) }
      }
    end
  end
end
