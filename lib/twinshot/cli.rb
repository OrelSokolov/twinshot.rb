# frozen_string_literal: true

require "json"
require "optparse"
require_relative "progress"

module Twinshot
  # Command-line interface: twinshot help | generate | compare.
  #
  # Exit codes: 0 — all pass (or command succeeded), 1 — parity differences
  # found (or a generate command failed), 2 — usage or config error.
  class CLI
    EXIT_OK = 0
    EXIT_DIFF = 1
    EXIT_ERROR = 2

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
      @config_path = nil
      @jobs = nil
      @json = false
      @helped = false
    end

    def call
      global_parser.order!(@argv)
      return version_text if @version
      if @helped
        @out.puts global_parser
        return EXIT_OK
      end

      command = @argv.shift
      case command
      when "compare" then compare
      when "generate" then generate
      when "help" then help
      when nil
        @err.puts global_parser
        EXIT_ERROR
      else
        @err.puts "twinshot: unknown command #{command.inspect}"
        @err.puts global_parser
        EXIT_ERROR
      end
    rescue OptionParser::ParseError, Config::Error, Compare::Error => e
      @err.puts "twinshot: #{e.message}"
      EXIT_ERROR
    end

    private

    def version_text
      @out.puts "twinshot #{Twinshot::VERSION}"
      EXIT_OK
    end

    def global_parser
      OptionParser.new do |o|
        o.banner = "twinshot — 1:1 artifact parity: oracle vs current"
        o.separator ""
        o.separator "Usage: twinshot [options] COMMAND [options]"
        o.separator ""
        o.separator "Commands:"
        o.separator "  compare            compare oracle and current trees, write the report"
        o.separator "  generate SIDE      run the generate command for oracle|current"
        o.separator "  help [COMMAND]     show help"
        o.separator ""
        o.separator "Options:"
        o.on("-c", "--config PATH", "Path to twinshot.yml (default: #{Config::DEFAULT_FILENAME})") do |v|
          @config_path = v
        end
        o.on("-V", "--version", "Show version") { @version = true }
        o.on("-h", "--help", "Show this help") { @helped = true }
      end
    end

    def compare_parser
      OptionParser.new do |o|
        o.banner = "Usage: twinshot compare [-c PATH] [-j N] [--json]"
        o.separator ""
        o.separator "Compares the oracle and current trees: structure first, then every"
        o.separator "file through a format adapter (png/html/txt/binary). Unknown files"
        o.separator "and structure mismatches are failures. Writes twinshot-report/"
        o.separator "(report.html + summary.json + diffs/)."
        o.separator ""
        o.separator "Exit status: 0 — all pass, 1 — differences found, 2 — config error."
        o.separator ""
        o.separator "Options:"
        o.on("-c", "--config PATH", "Path to twinshot.yml (default: #{Config::DEFAULT_FILENAME})") do |v|
          @config_path = v
        end
        o.on("-j", "--jobs N", Integer, "Worker processes (default: auto, capped at #{Compare::MAX_WORKERS})") do |v|
          @jobs = v
        end
        o.on("--json", "Print the machine summary to stdout") { @json = true }
        o.on("-h", "--help", "Show this help") { @helped = true }
      end
    end

    def generate_parser
      OptionParser.new do |o|
        o.banner = "Usage: twinshot generate oracle|current"
        o.separator ""
        o.separator "Runs the generate command configured for that side"
        o.separator "(oracle.generate / current.generate in twinshot.yml), with the"
        o.separator "config's directory as cwd. Optional: a compare run just takes"
        o.separator "the two directories as they are."
        o.separator ""
        o.separator "Exit status: 0 — command succeeded, 1 — command failed,"
        o.separator "2 — nothing configured / usage error."
        o.separator ""
        o.separator "Options:"
        o.on("-c", "--config PATH", "Path to twinshot.yml (default: #{Config::DEFAULT_FILENAME})") do |v|
          @config_path = v
        end
        o.on("-h", "--help", "Show this help") { @helped = true }
      end
    end

    def compare
      compare_parser.order!(@argv)
      if @helped
        @out.puts compare_parser
        return EXIT_OK
      end

      config = Config.load(@config_path)
      progress = Progress.new(out: @out, quiet: @json)
      summary = Compare.new(config).run(jobs: @jobs, progress: progress)
      Report.new(config, summary).write
      @out.puts JSON.pretty_generate(summary) if @json
      progress.summary(summary, File.join(config.report_dir, "report.html"))
      summary["failed"].zero? ? EXIT_OK : EXIT_DIFF
    end

    def generate
      generate_parser.order!(@argv)
      if @helped
        @out.puts generate_parser
        return EXIT_OK
      end

      side = @argv.shift
      unless %w[oracle current].include?(side)
        @err.puts "twinshot: expected 'oracle' or 'current', got #{side.inspect}"
        @err.puts generate_parser
        return EXIT_ERROR
      end

      config = Config.load(@config_path)
      command = config.generate_command(side)
      unless command
        @err.puts "twinshot: no #{side}.generate configured in #{File.basename(config.path)}"
        return EXIT_ERROR
      end

      @out.puts "twinshot: #{command}"
      system(command, chdir: config.root) ? EXIT_OK : EXIT_DIFF
    end

    def help
      topic = @argv.shift
      text = case topic
             when nil then global_parser.to_s
             when "compare" then compare_parser.to_s
             when "generate" then generate_parser.to_s
             else
               @err.puts "twinshot: unknown help topic #{topic.inspect} (expected compare or generate)"
               return EXIT_ERROR
             end
      @out.puts text
      EXIT_OK
    end
  end
end
