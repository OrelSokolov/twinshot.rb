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
      @open = nil
      @group = nil
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
        o.separator "  compare            compare every group (oracle vs current trees), write reports"
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
        o.banner = "Usage: twinshot compare [-c PATH] [-j N] [--json] [--[no-]open]"
        o.separator ""
        o.separator "Compares the oracle and current trees: structure first, then every"
        o.separator "file through a format adapter (png/html/txt/binary). Unknown files"
        o.separator "and structure mismatches are failures. Writes twinshot-report/"
        o.separator "(report_for_human.html + report_for_agent.md + summary.json + diffs/)."
        o.separator ""
        o.separator "Exit status: 0 — all pass, 1 — differences found, 2 — config error."
        o.separator "soft_check paths downgrade content diffs to warnings: shown"
        o.separator "in the reports, never change the exit code."
        o.separator ""
        o.separator "Options:"
        o.on("-c", "--config PATH", "Path to twinshot.yml (default: #{Config::DEFAULT_FILENAME})") do |v|
          @config_path = v
        end
        o.on("-j", "--jobs N", Integer, "Worker processes (default: auto, capped at #{Compare::MAX_WORKERS})") do |v|
          @jobs = v
        end
        o.on("--json", "Print the machine summary to stdout") { @json = true }
        o.on("--[no-]open", "Open the report in the default browser",
             "(default: on when stdout is a tty)") { |v| @open = v }
        o.on("-h", "--help", "Show this help") { @helped = true }
      end
    end

    def generate_parser
      OptionParser.new do |o|
        o.banner = "Usage: twinshot generate [-c PATH] [-g NAME] [oracle|current]"
        o.separator ""
        o.separator "Runs the generate commands configured in twinshot.yml, with"
        o.separator "the config's directory as cwd. With a side: that tree only"
        o.separator "(default group unless -g). Without a side: every configured"
        o.separator "tree — all groups, oracle then current — announced as a list"
        o.separator "and regenerated sequentially. Optional: a compare run just"
        o.separator "takes the two directories as they are."
        o.separator ""
        o.separator "Exit status: 0 — all commands succeeded, 1 — a command failed,"
        o.separator "2 — nothing configured / usage error."
        o.separator ""
        o.separator "Options:"
        o.on("-c", "--config PATH", "Path to twinshot.yml (default: #{Config::DEFAULT_FILENAME})") do |v|
          @config_path = v
        end
        o.on("-g", "--group NAME", "Group to generate for, or 'all' (default: #{Config::DEFAULT_GROUP})") do |v|
          @group = v
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
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      summary = Compare.new(config).run(jobs: @jobs, progress: progress)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      Report.new(config, summary).write
      @out.puts JSON.pretty_generate(summary) if @json
      progress.summary(summary, config.report_root, elapsed: elapsed)
      open_report(config)
      summary["failed"].zero? ? EXIT_OK : EXIT_DIFF
    end

    # The report opens in the browser after a compare run: by default when
    # stdout is a tty (so CI and --json stay quiet), --open forces it,
    # --no-open turns it off. A failed launch is a warning, not a parity
    # result — it never changes the exit code.
    def open_report(config)
      should_open = @open.nil? ? !@json && @out.tty? : @open
      return unless should_open

      Opener.open(File.join(config.report_dir, Config::HUMAN_REPORT))
    rescue Opener::Error => e
      @err.puts "twinshot: #{e.message}"
    end

    def generate
      generate_parser.order!(@argv)
      if @helped
        @out.puts generate_parser
        return EXIT_OK
      end

      side = @argv.shift
      unless side.nil? || Config::SIDES.include?(side)
        @err.puts "twinshot: expected 'oracle' or 'current', got #{side.inspect}"
        @err.puts generate_parser
        return EXIT_ERROR
      end

      config = Config.load(@config_path)
      # A bare `generate SIDE` stays default-group-only (as before); no side
      # at all — or -g all — means every group. Trees without a generate
      # command are simply skipped.
      groups = if @group.nil? && side || @group && @group != "all"
                 [config.group(@group || Config::DEFAULT_GROUP)]
               else
                 config.groups
               end
      sides = side ? [side] : Config::SIDES
      targets = groups.flat_map do |g|
        sides.filter_map do |s|
          command = g.generate_command(s)
          [g, s, command] if command
        end
      end
      if targets.empty?
        what = side ? "#{side}.generate" : "generate"
        scope = groups.size == 1 ? "for group #{groups.first.name}" : "in any selected group"
        @err.puts "twinshot: no #{what} configured #{scope} in #{File.basename(config.path)}"
        return EXIT_ERROR
      end

      # Say it first — the full list of trees about to be regenerated — then
      # run them one by one; a failing command doesn't stop the rest.
      @out.puts "Generate:"
      targets.each { |group, tree, _command| @out.puts "- #{group.name}/#{tree}" }
      results = targets.map do |group, tree, command|
        @out.puts "twinshot: [#{group.name}/#{tree}] #{command}"
        system(command, chdir: config.root)
      end
      results.all? ? EXIT_OK : EXIT_DIFF
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
