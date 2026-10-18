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
    assert_includes @out.string, "compare every group (oracle vs current trees), write reports"
  end

  def test_help_topic
    assert_equal 0, run_cli("help", "compare")
    assert_includes @out.string, "Usage: twinshot compare"
    assert_equal 0, run_cli("help", "generate")
    assert_includes @out.string, "Usage: twinshot generate"
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
      assert_equal 2, run_cli("-c", config_path(tmp, tmp), "generate", "oracle")
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
      assert_equal 0, run_cli("-c", config, "generate", "-g", "dogs", "oracle")
      assert File.exist?(marker)
      assert_equal 2, run_cli("-c", config, "generate", "-g", "cats", "oracle")
      assert_includes @err.string, 'unknown group: "cats"'
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
      assert_equal 0, run_cli("-c", config, "generate", "-g", "all", "oracle")
      assert File.exist?(File.join(tmp, "default-generated"))
      assert File.exist?(File.join(tmp, "dog-generated"))
    end
  end

  private

  def run_cli(*args, tty: false, json: false)
    @out = StringIO.new
    @out.define_singleton_method(:tty?) { true } if tty
    @err = StringIO.new
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
