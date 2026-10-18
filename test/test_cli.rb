# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class TestCli < Minitest::Test
  def test_global_help_exits_zero
    exit_code = run_cli("help")
    assert_equal 0, exit_code
    assert_includes @out.string, "twinshot — 1:1 artifact parity"
    assert_includes @out.string, "compare oracle and current trees"
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

      differing = make_trees(tmp, diff: true)
      assert_equal 1, run_cli("-c", config_path(tmp, differing), "compare", "--json")
      assert_includes @out.string, '"failed"'
    end
  end

  def test_compare_writes_report
    Dir.mktmpdir do |tmp|
      make_trees(tmp, diff: true)
      run_cli("-c", config_path(tmp, tmp), "compare")
      assert File.exist?(File.join(tmp, "twinshot-report", "report.html"))
      assert File.exist?(File.join(tmp, "twinshot-report", "summary.json"))
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
      File.write(config, File.read(config).sub("path: #{tmp}/oracle", "path: #{tmp}/oracle\n  generate: touch generated"))
      assert_equal 0, run_cli("-c", config, "generate", "oracle")
      assert File.exist?(marker)
    end
  end

  private

  def run_cli(*args)
    @out = StringIO.new
    @err = StringIO.new
    Twinshot::CLI.new(args, out: @out, err: @err).call
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
