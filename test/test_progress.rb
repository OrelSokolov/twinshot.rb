# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class TestProgress < Minitest::Test
  def test_announces_every_result_and_summary
    out = StringIO.new
    progress = Twinshot::Progress.new(out: out)
    config = make_config
    progress.banner(config, oracle_count: 2, current_count: 3, total: 4, workers: 2)
    [
      { "rel" => "a/one.txt", "kind" => "txt", "status" => "pass", "detail" => "lines identical" },
      { "rel" => "a/two.png", "kind" => "png", "status" => "fail", "detail" => "6.2% px differ" }
    ].each { |r| progress.result(r) }
    progress.summary({ "total" => 2, "passed" => 1, "failed" => 1,
                       "results" => [{ "kind" => "png", "status" => "fail" }] },
                     "/tmp/report.html")
    lines = out.string.lines
    assert_includes lines[0], "twinshot — 1:1 parity"
    assert_match(/oracle\s+\S+ \(2 files\)/, lines[1])
    assert_match(/4 results · 2 workers/, lines[3])
    assert_match(/\[ *1\/4 *\] ✓ a\/one\.txt — lines identical/, lines[5])
    assert_match(/\[ *2\/4 *\] ✗ a\/two\.png — 6\.2% px differ/, lines[6])
    assert_match(/FAIL: 1\/2 failed \(png: 1\)/, lines[8])
    assert_includes lines[9], "report: /tmp/report.html"
    refute_includes out.string, "\e[" # no ANSI when not a tty
  end

  def test_ok_summary
    out = StringIO.new
    progress = Twinshot::Progress.new(out: out)
    progress.summary({ "total" => 2, "passed" => 2, "failed" => 0, "results" => [] }, "/tmp/r.html")
    assert_includes out.string, "OK: 2/2 passed"
  end

  def test_quiet_is_silent
    progress = Twinshot::Progress.new(out: StringIO.new, quiet: true)
    progress.banner(make_config, oracle_count: 1, current_count: 1, total: 1, workers: 1)
    progress.result({ "rel" => "x", "kind" => "txt", "status" => "pass", "detail" => "" })
    progress.summary({ "total" => 1, "passed" => 1, "failed" => 0, "results" => [] }, "/tmp/r")
    # no crash, nothing to assert — quiet progress prints nothing
  end

  def test_compare_drives_progress
    Dir.mktmpdir do |tmp|
      oracle = File.join(tmp, "oracle")
      current = File.join(tmp, "current")
      %w[oracle current].each do |side|
        dir = File.join(tmp, side)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "page.txt"), side == "current" ? "other\n" : "same\n")
      end
      config_path = File.join(tmp, "twinshot.yml")
      File.write(config_path, "oracle: {path: #{oracle}}\ncurrent: {path: #{current}}\n")
      config = Twinshot::Config.load(config_path)

      out = StringIO.new
      progress = Twinshot::Progress.new(out: out)
      summary = Twinshot::Compare.new(config).run(jobs: 2, progress: progress)
      progress.summary(summary, "/tmp/report.html")
      lines = out.string.lines
      assert_equal summary["total"], lines.count { |l| l.include?("[") && (l.include?("✓") || l.include?("✗")) }
      assert_match(/FAIL: 1\/1 failed/, out.string)
    end
  end

  private

  def make_config
    Twinshot::Config.load(write_config(<<~YAML))
      oracle: {path: /tmp/o}
      current: {path: /tmp/c}
    YAML
  end

  def write_config(content)
    @config_path ||= begin
      path = File.join(Dir.mktmpdir("twinshot-progress"), "twinshot.yml")
      File.write(path, content)
      path
    end
  end
end
