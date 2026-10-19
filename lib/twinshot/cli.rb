# frozen_string_literal: true

require "json"
require "optparse"
require "shellwords"
require "fileutils"
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
      @helped = false
    end

    # Words bash feeds to the hidden completion helper. `completion install`
    # registers the `complete -C` one-liner that triggers this path.
    COMMANDS = %w[compare generate help completion].freeze

    def call
      # `complete -C twinshot twinshot` protocol: bash runs us with
      # COMP_LINE/COMP_POINT in the env and argv ["twinshot", cur, prev].
      # Intercepted first — before option parsing — so a half-typed option
      # can't raise. Hidden: never listed anywhere.
      return complete_c if completer_invocation?

      # Same candidates from words on the command line, for manual use and
      # tests: twinshot __complete WORD... (last word = one being completed).
      return complete(@argv.drop(1)) if @argv.first == "__complete"

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
      when "completion" then completion
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
        o.separator "  compare [GROUP|all]  compare every group or just one (oracle vs"
        o.separator "                      current trees), write reports"
        o.separator "  generate [GROUP:SIDE] run generate commands: dogs:oracle, a bare"
        o.separator "                      side (default group), a group, or 'all'"
        o.separator "  completion install install bash completion (works on the next TAB)"
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
        o.banner = "Usage: twinshot compare [GROUP|all] [-c PATH] [-j N] [--json] [--[no-]open]"
        o.separator ""
        o.separator "Compares the oracle and current trees: structure first, then every"
        o.separator "file through a format adapter (png/html/txt/binary). Unknown files"
        o.separator "and structure mismatches are failures. With GROUP only that group"
        o.separator "runs and only its report is written; 'all' (the default) — every"
        o.separator "configured group. Each compared group gets its own folder in"
        o.separator "twinshot-report/ (report_for_human.html + report_for_agent.md"
        o.separator "+ summary.json + diffs/)."
        o.separator ""
        o.separator "Exit status: 0 — all pass, 1 — differences found, 2 — config error."
        o.separator "soft_check entries are exact paths or globs (code/x/*);"
        o.separator "their content diffs and missing/extra structure results"
        o.separator "downgrade to warnings: shown in the reports, never change"
        o.separator "the exit code."
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
        o.banner = "Usage: twinshot generate [GROUP|all|SIDE][:oracle|current]"
        o.separator ""
        o.separator "Runs the generate commands configured in twinshot.yml, with"
        o.separator "the config's directory as cwd. The selector picks what to"
        o.separator "regenerate:"
        o.separator "  dogs:oracle, dogs:current  one tree of a named group"
        o.separator "  oracle, current            the default group's tree (no"
        o.separator "                             namespace means default, as in"
        o.separator "                             default:oracle)"
        o.separator "  dogs                       a whole group: both trees"
        o.separator "  all, all:oracle            every group: both trees, or one"
        o.separator "                             side of every group"
        o.separator "No selector at all: every configured tree — all groups,"
        o.separator "oracle then current — announced as a list and regenerated"
        o.separator "sequentially. Optional: a compare run just takes the two"
        o.separator "directories as they are."
        o.separator ""
        o.separator "Exit status: 0 — all commands succeeded, 1 — a command failed,"
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
      groups = select_groups(config)
      progress = Progress.new(out: @out, quiet: @json)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      summary = Compare.new(config).run(jobs: @jobs, progress: progress, groups: groups)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      Report.new(config, summary).write
      @out.puts JSON.pretty_generate(summary) if @json
      progress.summary(summary, config.report_root, elapsed: elapsed)
      open_report(config, groups)
      summary["failed"].zero? ? EXIT_OK : EXIT_DIFF
    end

    # The report opens in the browser after a compare run: by default when
    # stdout is a tty (so CI and --json stay quiet), --open forces it,
    # --no-open turns it off. The first compared group's report is the one
    # opened. A failed launch is a warning, not a parity result — it never
    # changes the exit code.
    def open_report(config, groups)
      should_open = @open.nil? ? !@json && @out.tty? : @open
      return unless should_open

      Opener.open(File.join(config.report_dir(groups.first), Config::HUMAN_REPORT))
    rescue Opener::Error => e
      @err.puts "twinshot: #{e.message}"
    end

    # The positional GROUP|all selector shared by compare and generate:
    # 'all' or nothing — every configured group, otherwise the named one
    # (Config#group raises on an unknown name).
    def select_groups(config)
      selector = @argv.shift
      return config.groups if selector.nil? || selector == "all"

      [config.group(selector)]
    end

    # The generate selector [GROUP|all|SIDE][:SIDE]. 'dogs:oracle' — one
    # tree of a named group; a bare side ('oracle') — the default group's
    # tree, no namespace means default ('default:oracle' is the same thing);
    # 'dogs' — both trees of one group; 'all', 'all:oracle' or nothing —
    # every group, both trees or one side. Group names can never be sides
    # (reserved in Config), so a bare side is unambiguous.
    def generate_selection(config, selector)
      return [config.groups, nil] if selector.nil? || selector == "all"

      name, side = selector.split(":", 2)
      return [[config.group(Config::DEFAULT_GROUP)], name] if side.nil? && Config::SIDES.include?(name)

      unless side.nil? || Config::SIDES.include?(side)
        raise Config::Error, "unknown side: #{side.inspect} in #{selector.inspect} (expected oracle or current)"
      end

      groups = if name == "all" then config.groups
               elsif name.empty? then [config.group(Config::DEFAULT_GROUP)]
               else [config.group(name)]
               end
      [groups, side]
    end

    def generate
      generate_parser.order!(@argv)
      if @helped
        @out.puts generate_parser
        return EXIT_OK
      end

      config = Config.load(@config_path)
      groups, side = generate_selection(config, @argv.shift)
      if (extra = @argv.shift)
        @err.puts "twinshot: unexpected argument #{extra.inspect}"
        @err.puts generate_parser
        return EXIT_ERROR
      end

      # Trees without a generate command are simply skipped.
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

    # The `complete -C` contract: bash passes the whole line in COMP_LINE and
    # the cursor in COMP_POINT; argv is ["twinshot", cur, prev]. Split the
    # line up to the cursor the way bash word-splits it, drop the program
    # name, make sure a word is being completed (append "" after a trailing
    # space), and reuse the shared candidate logic.
    def complete_c
      line = ENV.fetch("COMP_LINE", "")
      before = line[0, [ENV.fetch("COMP_POINT", line.length).to_i, line.length].min]
      words = begin
        Shellwords.split(before)
      rescue ArgumentError # unbalanced quote mid-word while typing
        before.split
      end
      words = words.drop(1)
      words << "" if before.empty? || before.end_with?(" ")
      complete(words)
    end

    def completer_invocation?
      ENV.key?("COMP_LINE") && @argv.size == 3 && @argv.first == "twinshot"
    end

    # Completion: prints the candidates for the words typed so far, one per
    # line. `words` is everything after `twinshot`; the last word is the one
    # being completed (possibly empty), the rest are what the user already
    # typed. We filter by prefix ourselves, so callers (the complete -C
    # protocol, `__complete`, tests) get the final list as-is.
    def complete(words)
      current = words.last.to_s
      typed = words[0...-1]
      candidates_for(typed, current).select { |c| c.start_with?(current) }.each { |c| @out.puts c }
      EXIT_OK
    end

    def candidates_for(typed, current = "")
      case completion_command(typed)
      when nil then COMMANDS + parser_flags(global_parser)
      when "help" then COMMANDS
      when "completion" then %w[install]
      when "compare"
        # Only the first positional is a group name (or 'all'); after that —
        # and for a bogus word — just the options.
        positionals(typed).empty? ? group_candidates(typed) | parser_flags(compare_parser) : parser_flags(compare_parser)
      when "generate"
        flags = parser_flags(generate_parser)
        if positionals(typed).empty?
          # Half-typed 'GROUP:' completes the sides; otherwise group names,
          # 'all' and the bare sides (a bare side = the default group).
          return side_completions(current) if current.include?(":")

          group_candidates(typed) | flags | Config::SIDES
        else
          flags
        end
      else
        []
      end
    end

    # 'dogs:<TAB>' / 'all:<TAB>' → the side spellings on that prefix.
    def side_completions(current)
      prefix = current[0..current.index(":")]
      ["#{prefix}oracle", "#{prefix}current"]
    end

    # The command word, skipping global flags and their values that may
    # precede it (`twinshot -c x.yml generate ...`). nil — no command yet.
    def completion_command(typed)
      walk_flags(typed) { |word, _i| return word }
      nil
    end

    # Positional words after the command, with flags and their values
    # (-c/--config) skipped.
    def positionals(typed)
      command = completion_command(typed)
      return [] unless command

      rest = typed.drop(typed.index(command) + 1)
      found = []
      walk_flags(rest) { |word, _i| found << word }
      found
    end

    def walk_flags(words)
      i = 0
      while i < words.size
        case words[i]
        when "-c", "--config" then i += 2
        when /\A-/ then i += 1
        else yield words[i], i
             i += 1
        end
      end
    end

    # The flag spellings straight out of the parser, so completion can never
    # drift from the real options. summarize() renders each switch as
    # "    -c, --config PATH        description" — keep option lines, take the
    # flag column (first run of the line), drop trailing commas and argument
    # names (PATH, N), and expand --[no-]open into both spellings.
    def parser_flags(parser)
      parser.summarize.map(&:strip)
            .select { |line| line.start_with?("-") }
            .flat_map { |line| line.split(/\s{2,}/).first.to_s.split }
            .map { |token| token.chomp(",") }
            .select { |token| token.start_with?("-") }
            .flat_map do |flag|
        if flag =~ /\A--\[no-\](\S+)\z/
          ["--#{Regexp.last_match(1)}",
           "--no-#{Regexp.last_match(1)}"]
        else
          [flag]
        end
      end
    end

    # Group names for the first positional of compare/generate, read from
    # the config the user pointed at (or the default one), plus 'all'. Any
    # config problem — missing file, bad YAML — quietly leaves `all` as the
    # only candidate.
    def group_candidates(typed)
      flag = typed.rindex("-c") || typed.rindex("--config")
      Config.load(flag && typed[flag + 1]).groups.map(&:name) + ["all"]
    rescue Config::Error
      ["all"]
    end

    # `twinshot completion install`: writes the `complete -C` one-liner into
    # the bash-completion user dir, which bash-completion lazy-loads on the
    # first TAB — no .bashrc edits, nothing sourced manually. Uninstall is
    # just deleting the file.
    def completion
      action = @argv.shift
      case action
      when "install"
        dir = File.join(data_home, "bash-completion", "completions")
        target = File.join(dir, "twinshot")
        FileUtils.mkdir_p(dir)
        File.write(target, "complete -C twinshot twinshot\n")
        @out.puts "Wrote #{target}"
        @out.puts "Completion is live in a new shell (loaded on your first TAB)."
        EXIT_OK
      else
        @err.puts "twinshot: expected 'completion install'"
        EXIT_ERROR
      end
    end

    def data_home
      xdg = ENV["XDG_DATA_HOME"]
      xdg&.start_with?("/") ? xdg : File.join(Dir.home, ".local", "share")
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
