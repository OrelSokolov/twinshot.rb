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
      assert_equal File.join(dir, "twinshot-report", "default"), config.report_dir
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

  def test_soft_check_matches_exact_paths_and_globs
    Dir.mktmpdir do |dir|
      config = Twinshot::Config.load(write_config(dir, <<~YAML))
        oracle: {path: o}
        current: {path: c}
        soft_check:
          - dashboard/header.png
          - code/capybara-tests/*
      YAML
      assert_equal ["dashboard/header.png", "code/capybara-tests/*"], config.soft_check
      assert config.soft_check?("dashboard/header.png") # exact path
      assert config.soft_check?("code/capybara-tests/run.code.txt")
      assert config.soft_check?("code/capybara-tests/tests/01_auth_test.code.txt") # * crosses /
      assert config.soft_check?("code/capybara-tests/.gitignore.code.txt") # dotfiles match *
      refute config.soft_check?("dashboard/other.png")
      refute config.soft_check?("dashboard") # folders are not file paths
      refute config.soft_check?("code/docs/readme.code.txt") # sibling subtree
    end
  end

  def test_soft_check_invalid_raises
    ["soft_check: dashboard\n", "soft_check: {a: b}\n", "soft_check: [\"\"]\n", "soft_check: [3]\n"].each do |soft|
      Dir.mktmpdir do |dir|
        path = write_config(dir, "oracle: {path: o}\ncurrent: {path: c}\n#{soft}")
        error = assert_raises(Twinshot::Config::Error) { Twinshot::Config.load(path) }
        assert_match(/soft_check/, error.message)
      end
    end
  end

  def test_unknown_generate_side_raises
    Dir.mktmpdir do |dir|
      config = Twinshot::Config.load(write_config(dir, "oracle: {path: o}\ncurrent: {path: c}\n"))
      error = assert_raises(Twinshot::Config::Error) { config.generate_command("middle") }
      assert_match(/unknown side/, error.message)
    end
  end

  def test_default_group_is_always_first
    Dir.mktmpdir do |dir|
      config = Twinshot::Config.load(write_config(dir, <<~YAML))
        oracle: {path: o}
        current: {path: c}
        groups:
          dogs:
            oracle: {path: dogs-o}
            current: {path: dogs-c}
      YAML
      assert_equal %w[default dogs], config.groups.map(&:name)
      assert_equal File.expand_path("o", dir), config.groups.first.oracle_path
      assert_equal File.expand_path("dogs-c", dir), config.groups.last.current_path
    end
  end

  def test_named_group_paths_generate_and_report_dir
    Dir.mktmpdir do |dir|
      config = Twinshot::Config.load(write_config(dir, <<~YAML))
        oracle: {path: o}
        current: {path: c}
        groups:
          dogs:
            oracle: {path: dogs-o, generate: bin/record --dogs}
            current: {path: /abs/dogs-c}
      YAML
      group = config.group("dogs")
      assert_equal File.expand_path("dogs-o", dir), group.oracle_path
      assert_equal "/abs/dogs-c", group.current_path
      assert_equal "bin/record --dogs", group.generate_command("oracle")
      assert_nil group.generate_command("current")
      assert_equal File.join(dir, "twinshot-report", "dogs"), config.report_dir(group)
      assert_equal File.join(dir, "twinshot-report", "default"), config.report_dir
    end
  end

  def test_named_group_missing_side_path_raises
    Dir.mktmpdir do |dir|
      path = write_config(dir, <<~YAML)
        oracle: {path: o}
        current: {path: c}
        groups:
          dogs:
            current: {path: dogs-c}
      YAML
      error = assert_raises(Twinshot::Config::Error) { Twinshot::Config.load(path) }
      assert_match(/groups\.dogs\.oracle\.path is required/, error.message)
    end
  end

  def test_reserved_group_name_raises
    Dir.mktmpdir do |dir|
      path = write_config(dir, <<~YAML)
        oracle: {path: o}
        current: {path: c}
        groups:
          default:
            oracle: {path: x}
            current: {path: y}
      YAML
      error = assert_raises(Twinshot::Config::Error) { Twinshot::Config.load(path) }
      assert_match(/reserved/, error.message)
    end
  end

  def test_groups_not_a_mapping_raises
    Dir.mktmpdir do |dir|
      path = write_config(dir, "oracle: {path: o}\ncurrent: {path: c}\ngroups: [dogs]\n")
      error = assert_raises(Twinshot::Config::Error) { Twinshot::Config.load(path) }
      assert_match(/groups must be a mapping/, error.message)
    end
  end

  def test_unknown_group_raises
    Dir.mktmpdir do |dir|
      config = Twinshot::Config.load(write_config(dir, "oracle: {path: o}\ncurrent: {path: c}\n"))
      error = assert_raises(Twinshot::Config::Error) { config.group("cats") }
      assert_match(/unknown group: "cats"/, error.message)
    end
  end

  private

  def write_config(dir, content)
    path = File.join(dir, "twinshot.yml")
    File.write(path, content)
    path
  end
end
