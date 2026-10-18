# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestConfig < Minitest::Test
  def test_loads_paths_and_defaults
    Dir.mktmpdir do |dir|
      path = write_config(dir, <<~YAML)
        oracle:
          path: artifacts/rails
        current:
          path: /abs/crails
      YAML
      config = Twinshot::Config.load(path)
      assert_equal File.expand_path("artifacts/rails", dir), config.oracle_path
      assert_equal "/abs/crails", config.current_path
      assert_equal 0.002, config.max_diff_ratio
      assert_equal File.join(dir, "twinshot-report"), config.report_dir
      assert_nil config.generate_command("oracle")
    end
  end

  def test_generate_command_and_png_threshold
    Dir.mktmpdir do |dir|
      path = write_config(dir, <<~YAML)
        oracle:
          path: o
          generate: bin/record
        current:
          path: c
          generate: bin/record --crails
        png:
          max_diff_ratio: 0.05
      YAML
      config = Twinshot::Config.load(path)
      assert_equal "bin/record", config.generate_command("oracle")
      assert_equal "bin/record --crails", config.generate_command("current")
      assert_equal 0.05, config.max_diff_ratio
    end
  end

  def test_missing_side_path_raises
    Dir.mktmpdir do |dir|
      path = write_config(dir, "current:\n  path: x\n")
      error = assert_raises(Twinshot::Config::Error) { Twinshot::Config.load(path) }
      assert_match(/oracle\.path is required/, error.message)
    end
  end

  def test_missing_config_file_raises
    error = assert_raises(Twinshot::Config::Error) { Twinshot::Config.load("/nonexistent/x.yml") }
    assert_match(/config not found/, error.message)
  end

  def test_invalid_ratio_raises
    Dir.mktmpdir do |dir|
      path = write_config(dir, "oracle: {path: o}\ncurrent: {path: c}\npng: {max_diff_ratio: lots}\n")
      error = assert_raises(Twinshot::Config::Error) { Twinshot::Config.load(path) }
      assert_match(/max_diff_ratio must be a number/, error.message)
    end
  end

  def test_unknown_generate_side_raises
    Dir.mktmpdir do |dir|
      config = Twinshot::Config.load(write_config(dir, "oracle: {path: o}\ncurrent: {path: c}\n"))
      error = assert_raises(Twinshot::Config::Error) { config.generate_command("middle") }
      assert_match(/unknown side/, error.message)
    end
  end

  private

  def write_config(dir, content)
    path = File.join(dir, "twinshot.yml")
    File.write(path, content)
    path
  end
end
