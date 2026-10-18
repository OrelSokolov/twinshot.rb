# frozen_string_literal: true

module Twinshot
  module Adapters
    # Plain text: line-by-line diff. Pass when every line matches.
    module Txt
      module_function

      def call(_rel, oracle_file, current_file, _ctx)
        a_lines = read_lines(oracle_file)
        b_lines = read_lines(current_file)
        if a_lines == b_lines
          return { "kind" => "txt", "status" => "pass", "detail" => "lines identical" }
        end

        changed, entries = Adapters.line_diff(a_lines, b_lines)
        { "kind" => "txt", "status" => "fail", "detail" => "#{changed} line(s) differ",
          "diff_lines" => changed, "diff" => entries }
      end

      def read_lines(path)
        File.read(path, encoding: "UTF-8").gsub(/\r\n?/, "\n").lines.map(&:chomp)
      end
    end

    register(Txt, "txt", "md", "log", "json", "csv")
  end
end
