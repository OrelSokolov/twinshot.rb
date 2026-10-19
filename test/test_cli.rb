# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "vips"

class TestCli < Minitest::Test
  def test_global_help_exits_zero
    exit_code = run_cli("help")
    assert_equal 0, exit_code
    assert_includes @out.string, "twinshot — 1:1 artifact parity"
    assert_includes @out.string, "compare every group or just one (oracle vs"
  end

  def test_help_topic
    assert_equal 0, run_cli("help", "compare")
    assert_includes @out.string, "Usage: twinshot compare"
    assert_equal 0, run_cli("help", "generate")
    assert_includes @out.string, "Usage: twinshot generate"
    assert_equal 0, run_cli("help", "review")
    assert_includes @out.string, "Usage: twinshot review"
    assert_equal 2, run_cli("help", "bogus")
    assert_includes @err.string, "unknown help topic"
  end

  def test_no_command_is_usage_error
    assert_equal 2, run_cli
    assert_match(/Usage/, @err.string)
  end

  def test_unknown_command_is_usage_error
    assert_equal 2, run_cli("frobnicate")
    assert_includes @err.string, "unknown command"
  end

  def test_version
    assert_equal 0, run_cli("--version")
    assert_includes @out.string, Twinshot::VERSION
  end

  def test_compare_exit_codes
    Dir.mktmpdir do |tmp|
      identical = make_trees(tmp, diff: false)
      assert_equal 0, run_cli("-c", config_path(tmp, identical), "compare")
      assert_includes @out.string, "1/1 passed"
      assert_match(/Done in \d+\.\d+s/, @out.string)

      differing = make_trees(tmp, diff: true)
      assert_equal 1, run_cli("-c", config_path(tmp, differing), "compare", "--json")
      assert_includes @out.string, '"failed"'
    end
  end

  def test_compare_writes_report
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: true)
      run_cli("-c", config_path(tmp, tmp), "compare")
      assert File.exist?(File.join(tmp, "twinshot-report", "default", "report_for_human.html"))
      assert File.exist?(File.join(tmp, "twinshot-report", "default", "report_for_agent.md"))
      assert File.exist?(File.join(tmp, "twinshot-report", "default", "summary.json"))
      md = File.read(File.join(tmp, "twinshot-report", "default", "report_for_agent.md"))
      assert_includes md, "### page.txt"
      assert_includes md, "````diff"
      assert_includes md, "-same"
      assert_includes md, "+other"
    end
  end

  def test_compare_reports_per_group
    Dir.mktmpdir do |tmp|
      config = config_path(tmp, tmp)
      make_trees(tmp, diff: false)
      File.write(config, File.read(config) + <<~YAML)
        groups:
          dogs:
            oracle: {path: #{tmp}/oracle}
            current: {path: #{tmp}/current}
      YAML
      assert_equal 0, run_cli("-c", config, "compare")
      %w[default dogs].each do |group|
        assert File.exist?(File.join(tmp, "twinshot-report", group, "report_for_human.html")), group
        assert File.exist?(File.join(tmp, "twinshot-report", group, "report_for_agent.md")), group
        assert File.exist?(File.join(tmp, "twinshot-report", group, "summary.json")), group
      end
      summary = JSON.parse(File.read(File.join(tmp, "twinshot-report", "default", "summary.json")))
      assert_equal 1, summary["total"]
      assert_equal "default", summary["results"].first["group"]
    end
  end

  def test_compare_single_group_only
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      %w[dogs-oracle dogs-current].each { |d| FileUtils.mkdir_p(File.join(tmp, d)) }
      File.write(File.join(tmp, "dogs-oracle", "page.txt"), "same\n")
      File.write(File.join(tmp, "dogs-current", "page.txt"), "other\n")
      config = config_path(tmp, tmp)
      File.write(config, File.read(config) + <<~YAML)
        groups:
          dogs:
            oracle: {path: #{tmp}/dogs-oracle}
            current: {path: #{tmp}/dogs-current}
      YAML
      opened = []
      Twinshot::Opener.stub(:open, ->(path) { opened << path }) do
        # Only dogs runs: its diff fails the run, its report is the one opened,
        # and the default group's report is not written at all.
        assert_equal 1, run_cli("-c", config, "compare", "--open", "dogs")
      end
      assert File.exist?(File.join(tmp, "twinshot-report", "dogs", "report_for_human.html"))
      refute File.exist?(File.join(tmp, "twinshot-report", "default")), "default group must not run"
      assert_equal [File.join(tmp, "twinshot-report", "dogs", "report_for_human.html")], opened

      assert_equal 0, run_cli("-c", config, "compare", "default")
      assert File.exist?(File.join(tmp, "twinshot-report", "default", "report_for_human.html"))

      assert_equal 2, run_cli("-c", config, "compare", "cats")
      assert_includes @err.string, 'unknown group: "cats"'
    end
  end

  def test_compare_report_group_switcher
    Dir.mktmpdir do |tmp|
      config = config_path(tmp, tmp)
      make_trees(tmp, diff: true)
      File.write(config, File.read(config) + <<~YAML)
        groups:
          dogs:
            oracle: {path: #{tmp}/oracle}
            current: {path: #{tmp}/current}
      YAML
      run_cli("-c", config, "compare")
      %w[default dogs].each do |group|
        html = File.read(File.join(tmp, "twinshot-report", group, "report_for_human.html"))
        other = group == "default" ? "dogs" : "default"
        assert_includes html, %(class="dd-toggle"), "#{group}: dropdown toggle"
        assert_includes html, %(aria-expanded="false"), "#{group}: collapsed by default"
        assert_includes html, %(href="../#{other}/report_for_human.html"), "#{group}: link to #{other}"
        assert_includes html, %(href="../#{group}/report_for_human.html" class="active" aria-current="page"),
                        "#{group}: current group marked active"
      end
    end
  end

  def test_compare_report_single_group_has_no_switcher
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      run_cli("-c", config_path(tmp, tmp), "compare")
      html = File.read(File.join(tmp, "twinshot-report", "default", "report_for_human.html"))
      assert_includes html, %(<span id="gname">default</span>)
      refute_includes html, %(<div class="dropdown">)
    end
  end

  def test_compare_report_heat_overlay
    Dir.mktmpdir do |tmp|
      %w[oracle current].each do |side|
        dir = File.join(tmp, side)
        FileUtils.mkdir_p(dir)
        image = Vips::Image.black(4, 4, bands: 3).add([255, 0, 0])
        image = image.draw_rect([0, 255, 0], 1, 1, 1, 1) if side == "current"
        image.pngsave(File.join(dir, "shot.png"))
      end
      run_cli("-c", config_path(tmp, tmp), "compare")
      html = File.read(File.join(tmp, "twinshot-report", "default", "report_for_human.html"))
      assert_includes html, %(<div class="heat")
      assert_includes html, "background:rgba(160,32,240,0.3)"
      assert_includes html, %(data-h="on")
      assert_includes File.read(File.join(tmp, "twinshot-report", "default", "summary.json")), '"heat"'
    end
  end

  def test_compare_report_hides_overlay_img_in_side_mode
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      run_cli("-c", config_path(tmp, tmp), "compare")
      html = File.read(File.join(tmp, "twinshot-report", "default", "report_for_human.html"))
      # .pair .overlay must outrank .pair img{display:block} (which rendered the
      # overlay as a duplicate image stacked below the oracle shot).
      assert_includes html, ".pair .overlay{display:none}"
    end
  end

  def test_compare_report_heat_static_in_blink_mode
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      run_cli("-c", config_path(tmp, tmp), "compare")
      html = File.read(File.join(tmp, "twinshot-report", "default", "report_for_human.html"))
      # In blink mode the compare image itself flashes; the heat overlay must
      # stay static so it doesn't fight the blink comparison.
      assert_includes html, "body[data-mode=blink] .heat i{animation:none}"
    end
  end

  def test_compare_open_opens_default_group_report
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      opened = []
      Twinshot::Opener.stub(:open, ->(path) { opened << path }) do
        assert_equal 0, run_cli("-c", config_path(tmp, tmp), "compare", "--open")
      end
      assert_equal [File.join(tmp, "twinshot-report", "default", "report_for_human.html")], opened
      assert_empty @err.string
    end
  end

  def test_compare_opens_by_default_on_tty_only
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      config = config_path(tmp, tmp)
      opened = []
      Twinshot::Opener.stub(:open, ->(path) { opened << path }) do
        assert_equal 0, run_cli("-c", config, "compare", tty: true)
        assert_equal 1, opened.size, "tty run should open the report"
        assert_equal 0, run_cli("-c", config, "compare")
        assert_equal 1, opened.size, "non-tty run should not open the report"
        assert_equal 0, run_cli("-c", config, "compare", tty: true, json: true)
        assert_equal 1, opened.size, "--json run should not open the report"
      end
    end
  end

  def test_compare_no_open_stays_quiet_and_open_failure_warns_only
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      config = config_path(tmp, tmp)
      opened = []
      Twinshot::Opener.stub(:open, lambda { |path|
        opened << path
        raise Twinshot::Opener::Error, "`open boom` failed"
      }) do
        assert_equal 0, run_cli("-c", config, "compare", "--no-open", tty: true)
        assert_empty opened
        assert_equal 0, run_cli("-c", config, "compare", "--open", tty: true)
        assert_equal 1, opened.size
        assert_includes @err.string, "`open boom` failed"
      end
    end
  end

  def test_generate_without_command_configured
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      assert_equal 2, run_cli("-c", config_path(tmp, tmp), "generate", "default:oracle")
      assert_includes @err.string, "no oracle.generate configured"
    end
  end

  def test_generate_runs_command
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      marker = File.join(tmp, "generated")
      config = config_path(tmp, tmp)
      File.write(config,
                 File.read(config).sub("path: #{tmp}/oracle", "path: #{tmp}/oracle\n  generate: touch generated"))
      # A bare side — no namespace — means the default group.
      assert_equal 0, run_cli("-c", config, "generate", "oracle")
      assert File.exist?(marker)
    end
  end

  def test_generate_for_named_group
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      marker = File.join(tmp, "dog-generated")
      config = config_path(tmp, tmp)
      File.write(config, File.read(config) + <<~YAML)
        groups:
          dogs:
            oracle:
              path: #{tmp}/oracle
              generate: touch dog-generated
            current: {path: #{tmp}/current}
      YAML
      assert_equal 0, run_cli("-c", config, "generate", "dogs:oracle")
      assert File.exist?(marker)
      # current side has no generate command configured in the group
      assert_equal 2, run_cli("-c", config, "generate", "dogs:current")
      assert_includes @err.string, "no current.generate configured for group dogs"
      assert_equal 2, run_cli("-c", config, "generate", "cats:oracle")
      assert_includes @err.string, 'unknown group: "cats"'
      assert_equal 2, run_cli("-c", config, "generate", "dogs:bogus")
      assert_includes @err.string, 'unknown side: "bogus"'
      assert_equal 2, run_cli("-c", config, "generate", "dogs:oracle", "extra")
      assert_includes @err.string, 'unexpected argument "extra"'
    end
  end

  def test_generate_all_groups
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      config = config_path(tmp, tmp)
      content = File.read(config)
                    .sub("path: #{tmp}/oracle", "path: #{tmp}/oracle\n  generate: touch default-generated")
      content += <<~YAML
        groups:
          dogs:
            oracle:
              path: #{tmp}/oracle
              generate: touch dog-generated
            current: {path: #{tmp}/current}
      YAML
      File.write(config, content)
      assert_equal 0, run_cli("-c", config, "generate", "all:oracle")
      assert File.exist?(File.join(tmp, "default-generated"))
      assert File.exist?(File.join(tmp, "dog-generated"))
    end
  end

  def test_generate_all_trees_without_side
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      config = config_path(tmp, tmp)
      content = File.read(config)
                    .sub("path: #{tmp}/oracle", "path: #{tmp}/oracle\n  generate: touch o-default")
                    .sub("path: #{tmp}/current", "path: #{tmp}/current\n  generate: touch c-default")
      content += <<~YAML
        groups:
          dogs:
            oracle:
              path: #{tmp}/oracle
              generate: touch o-dogs
            current:
              path: #{tmp}/current
              generate: touch c-dogs
      YAML
      File.write(config, content)
      assert_equal 0, run_cli("-c", config, "generate")
      %w[o-default c-default o-dogs c-dogs].each { |m| assert File.exist?(File.join(tmp, m)), m }
      assert_includes @out.string, "Generate:"
      %w[default/oracle default/current dogs/oracle dogs/current].each do |label|
        assert_includes @out.string, "- #{label}"
      end
    end
  end

  def test_generate_without_side_runs_rest_after_failure
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      config = config_path(tmp, tmp)
      content = File.read(config)
                    .sub("path: #{tmp}/oracle", "path: #{tmp}/oracle\n  generate: \"false\"")
                    .sub("path: #{tmp}/current", "path: #{tmp}/current\n  generate: touch still-run")
      File.write(config, content)
      assert_equal 1, run_cli("-c", config, "generate")
      assert File.exist?(File.join(tmp, "still-run")), "a failed command must not stop the rest"
    end
  end

  def test_generate_without_side_nothing_configured
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      assert_equal 2, run_cli("-c", config_path(tmp, tmp), "generate")
      assert_includes @err.string, "no generate configured"
    end
  end

  def test_review_regenerates_then_compares
    Dir.mktmpdir do |tmp|
      # The trees differ until the generate commands rewrite them identically.
      make_trees(tmp, diff: true)
      config = config_path(tmp, tmp)
      File.write(config, <<~YAML)
        oracle:
          path: #{tmp}/oracle
          generate: "echo same > #{tmp}/oracle/page.txt"
        current:
          path: #{tmp}/current
          generate: "echo same > #{tmp}/current/page.txt"
      YAML
      assert_equal 0, run_cli("-c", config, "review")
      assert_includes @out.string, "Generate:"
      %w[default/oracle default/current].each { |t| assert_includes @out.string, "- #{t}" }
      assert_includes @out.string, "1/1 passed"
      assert File.exist?(File.join(tmp, "twinshot-report", "default", "report_for_human.html"))
    end
  end

  def test_review_single_group_only
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      config = config_path(tmp, tmp)
      File.write(config, File.read(config) + <<~YAML)
        groups:
          dogs:
            oracle:
              path: #{tmp}/oracle
              generate: touch dog-generated
            current: {path: #{tmp}/current}
      YAML
      assert_equal 0, run_cli("-c", config, "review", "dogs")
      assert File.exist?(File.join(tmp, "dog-generated"))
      assert File.exist?(File.join(tmp, "twinshot-report", "dogs", "report_for_human.html"))
      refute File.exist?(File.join(tmp, "twinshot-report", "default")), "default group must not run"
      assert_equal 2, run_cli("-c", config, "review", "cats")
      assert_includes @err.string, 'unknown group: "cats"'
    end
  end

  def test_review_generate_failure_skips_compare
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      config = config_path(tmp, tmp)
      content = File.read(config)
                    .sub("path: #{tmp}/oracle", "path: #{tmp}/oracle\n  generate: \"false\"")
                    .sub("path: #{tmp}/current", "path: #{tmp}/current\n  generate: touch still-run")
      File.write(config, content)
      assert_equal 1, run_cli("-c", config, "review")
      assert File.exist?(File.join(tmp, "still-run")), "a failed command must not stop the rest"
      refute File.exist?(File.join(tmp, "twinshot-report")), "no reports over stale trees"
      # The failure is said out loud: which tree fell over and why compare never ran.
      assert_includes @err.string, "[default/oracle] generate command failed with exit 1"
      assert_includes @err.string, "generate failed — skipping compare"
      refute_includes @err.string, "\e[31m", "piped stderr stays plain"
      # ...and in red when stderr is a tty.
      assert_equal 1, run_cli("-c", config, "review", err_tty: true)
      assert_includes @err.string,
                      "twinshot: generate failed — skipping compare (a report over stale trees would be misleading)".red
    end
  end

  def test_review_without_generate_configured_is_plain_compare
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      assert_equal 0, run_cli("-c", config_path(tmp, tmp), "review")
      refute_includes @out.string, "Generate:"
      assert File.exist?(File.join(tmp, "twinshot-report", "default", "report_for_human.html"))
    end
  end

  def test_complete_top_level_commands_and_flags
    assert_equal 0, run_cli("__complete", "gen")
    assert_equal ["generate"], @out.string.split
    run_cli("__complete", "")
    words = @out.string.split
    %w[compare generate review help -c --config --version --help].each do |w|
      assert_includes words, w, w
    end
    refute_includes words, "__complete", "completion helper stays hidden"
  end

  def test_complete_flags_come_from_the_parsers
    run_cli("__complete", "compare", "")
    words = @out.string.split
    %w[-j --jobs --json --open --no-open all].each { |w| assert_includes words, w, w }
    run_cli("__complete", "generate", "")
    words = @out.string.split
    # no twinshot.yml here — the only group candidate is `all`, plus the
    # bare sides (a bare side = the default group)
    %w[all oracle current -c --config].each { |w| assert_includes words, w, w }
    # half-typed GROUP: completes the sides on that prefix
    assert_equal 0, run_cli("__complete", "generate", "dogs:")
    assert_equal %w[dogs:oracle dogs:current], @out.string.split
    run_cli("__complete", "generate", "all", "")
    words = @out.string.split
    assert_includes words, "--config"
    refute_includes words, "oracle", "the selector is a single word — nothing positional follows"
    refute_includes words, "all"
  end

  def test_complete_group_names_from_config
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: false)
      config = config_path(tmp, tmp)
      File.write(config, File.read(config) + <<~YAML)
        groups:
          dogs:
            oracle: {path: #{tmp}/oracle}
            current: {path: #{tmp}/current}
      YAML
      assert_equal 0, run_cli("__complete", "-c", config, "generate", "")
      words = @out.string.split
      %w[all default dogs].each { |w| assert_includes words, w, w }
      assert_equal 0, run_cli("__complete", "-c", config, "compare", "")
      assert_includes @out.string.split, "dogs"
    end
  end

  def test_complete_c_protocol
    with_env("COMP_LINE" => "twinshot gen", "COMP_POINT" => "12") do
      assert_equal 0, run_cli("twinshot", "gen", "twinshot")
      assert_equal ["generate"], @out.string.split
    end
    line = "twinshot generate "
    with_env("COMP_LINE" => line, "COMP_POINT" => line.length.to_s) do
      Dir.mktmpdir do |tmp|
        make_trees(tmp, diff: false)
        assert_equal 0, run_cli("twinshot", "", "generate")
        # no twinshot.yml here — the only group candidate is `all`
        assert_includes @out.string.split, "all"
        refute_includes @out.string.split, "default"
      end
    end
  end

  def test_completion_install_writes_bash_completion_one_liner
    Dir.mktmpdir do |home|
      with_env("HOME" => home, "XDG_DATA_HOME" => nil) do
        assert_equal 0, run_cli("completion", "install")
        target = File.join(home, ".local/share/bash-completion/completions/twinshot")
        assert_equal "complete -C twinshot twinshot\n", File.read(target)
        assert_includes @out.string, target
      end
    end
  end

  def test_completion_without_action_is_usage_error
    assert_equal 2, run_cli("completion")
    assert_equal 2, run_cli("completion", "bogus")
    assert_includes @err.string, "expected 'completion install'"
  end

  private

  # Sets ENV keys for the block, restoring (or deleting, for nil values) after.
  def with_env(pairs)
    saved = pairs.keys.map { |k| [k, ENV[k]] }.to_h
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def run_cli(*args, tty: false, err_tty: false, json: false)
    @out = StringIO.new
    @out.define_singleton_method(:tty?) { true } if tty
    @err = StringIO.new
    @err.define_singleton_method(:tty?) { true } if err_tty
    argv = json ? args + ["--json"] : args
    Twinshot::CLI.new(argv, out: @out, err: @err).call
  end

  def config_path(base, tmp = nil)
    oracle = File.join(tmp || base, "oracle")
    current = File.join(tmp || base, "current")
    path = File.join(base, "twinshot-#{rand(1_000_000)}.yml")
    File.write(path, <<~YAML)
      oracle:
        path: #{oracle}
      current:
        path: #{current}
    YAML
    path
  end

  def make_trees(tmp, diff:)
    %w[oracle current].each do |side|
      dir = File.join(tmp, side)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "page.txt"), diff && side == "current" ? "other\n" : "same\n")
    end
    tmp
  end
end
