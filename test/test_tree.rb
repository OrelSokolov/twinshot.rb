# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestTree < Minitest::Test
  def test_files_sorted_relative_paths
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "o")
      write(root, "b/two.txt", "x")
      write(root, "a/one.txt", "x")
      write(root, "top.txt", "x")
      assert_equal %w[a/one.txt b/two.txt top.txt], Twinshot::Tree.files(root)
    end
  end

  def test_diff_finds_missing_and_extra
    oracle_files = %w[a/one.txt a/two.txt shared.txt]
    current_files = %w[a/two.txt a/three.txt shared.txt]
    diff = Twinshot::Tree.diff(oracle_files, current_files)
    assert_equal ["a/one.txt"], diff["missing"]
    assert_equal ["a/three.txt"], diff["extra"]
  end

  def test_diff_identical_trees
    diff = Twinshot::Tree.diff(%w[x.txt], %w[x.txt])
    assert_empty diff["missing"]
    assert_empty diff["extra"]
  end

  private

  def write(root, rel, content)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
