# frozen_string_literal: true

require "colorize"

module Twinshot
  # Human-friendly run progress on stdout: banner, one line per result with
  # color, summary block. Colors only when the output is a tty; fully silent
  # when quiet (e.g. --json).
  class Progress
    def initialize(out: $stdout, quiet: false)
      @out = quiet ? nil : out
      @color = !@out.nil? && @out.tty?
      @index = 0
      @total = nil
      @fails = []
      @warns = []
    end

    def banner(config, group:, oracle_count:, current_count:, total:, workers:)
      @total = total
      @index = 0
      return unless @out

      @out.puts paint("twinshot — 1:1 parity · group #{group.name}", :bold)
      @out.puts "  oracle   #{display_path(group.oracle_path)} (#{oracle_count} files)"
      @out.puts "  current  #{display_path(group.current_path)} (#{current_count} files)"
      mode = workers == 1 ? "sequential" : "#{workers} workers"
      @out.puts "  #{total} results · #{mode} · png threshold #{format("%.2f", config.max_diff_ratio * 100)}%"
      @out.puts
    end

    def result(result)
      return unless @out

      @index += 1
      status = result["status"]
      @fails << result if status == "fail"
      @warns << result if status == "warn"
      mark, tone = case status
                   when "pass" then [paint("✓", :green), nil]
                   when "warn" then [paint("!", :yellow), :yellow]
                   else [paint("✗", :red), :red]
                   end
      detail = result["detail"].to_s
      detail = paint(detail, tone) if tone
      rel = result["group"] ? "#{result["group"]}/#{result["rel"]}" : result["rel"]
      @out.puts format("  [%3d/%-3d] %s %s — %s", @index, @total || "?", mark, rel, detail)
    end

    def summary(summary, report_path, elapsed: nil)
      return unless @out

      @out.puts
      if summary["failed"].zero?
        warned = summary["warned"].to_i
        ok = "OK: #{summary["passed"]}/#{summary["total"]} passed"
        ok = "#{ok} (#{warned} warn)" if warned.positive?
        @out.puts paint(ok, :green)
        if warned.positive?
          # Copyable list of every warned file (soft_check), like FAILS below.
          @out.puts paint("WARNS:", :yellow)
          @warns.each { |r| @out.puts paint(rel_path(r), :yellow) }
          @out.puts
        end
      else
        breakdown = summary["results"]
                    .select { |r| r["status"] == "fail" }
                    .group_by { |r| r["kind"] }
                    .map { |kind, rs| "#{kind}: #{rs.size}" }.join(", ")
        @out.puts paint("FAIL: #{summary["failed"]}/#{summary["total"]} failed (#{breakdown})", :red)
        # Copyable list of every failed file, printed once more as a group.
        @out.puts paint("FAILS:", :red)
        @fails.each { |r| @out.puts rel_path(r) }
        @out.puts
      end
      @out.puts "Done in #{format_duration(elapsed)}" if elapsed
      @out.puts "report: #{report_path}"
    end

    private

    def rel_path(result)
      result["group"] ? "#{result["group"]}/#{result["rel"]}" : result["rel"]
    end

    def paint(text, meth)
      return text.to_s unless @color

      text.to_s.public_send(meth)
    end

    def format_duration(seconds)
      return format("%.2fs", seconds) if seconds < 60

      format("%dm %.1fs", (seconds / 60).to_i, seconds % 60)
    end

    def display_path(path)
      Pathname.new(path).relative_path_from(Pathname.pwd).to_s
    rescue ArgumentError
      path
    end
  end
end
