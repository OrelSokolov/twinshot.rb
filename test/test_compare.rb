# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require "chunky_png"

class TestCompare < Minitest::Test
  def test_end_to_end_report_and_summary
    Dir.mktmpdir do |tmp|
      config = build_fixture(tmp)
      summary = Twinshot::Compare.new(config).run(jobs: 2)
      Twinshot::Report.new(config, summary).write

      by_rel = summary["results"].to_h { |r| [r["rel"], r] }
      assert_equal "pass", by_rel["a/one.txt"]["status"]
      assert_equal "pass", by_rel["b/deep.html"]["status"]
      assert_equal "fail", by_rel["a/two.png"]["status"]
      assert_match(/no adapter/, by_rel["c/odd.xyz"]["detail"])
      assert_equal "fail", by_rel["c/odd.xyz"]["status"]
      assert_match(/missing in current/, by_rel["d/only-oracle.txt"]["detail"])
      assert_match(/extra in current/, by_rel["e/only-current.txt"]["detail"])
      assert_equal 2, summary["passed"]
      assert_equal 4, summary["failed"]

      assert File.exist?(File.join(config.report_dir, "diffs", "a", "two.png.diff.png"))
      report_html = File.read(File.join(config.report_dir, "report.html"))
      assert_includes report_html, %(data-name="a/two.png")
      assert_includes report_html, %(data-name="e/only-current.txt")
      summary_json = JSON.parse(File.read(File.join(config.report_dir, "summary.json")))
      assert_equal summary["total"], summary_json["total"]
    end
  end

  def test_parallel_matches_sequential
    Dir.mktmpdir do |tmp|
      config = build_fixture(tmp)
      sequential = Twinshot::Compare.new(config).run(jobs: 1)
      parallel = Twinshot::Compare.new(config).run(jobs: 3)
      assert_equal sequential["results"], parallel["results"]
    end
  end

  private

  def build_fixture(tmp)
    oracle = File.join(tmp, "oracle")
    current = File.join(tmp, "current")
    write(oracle, "a/one.txt", "same\nlines\n")
    write(current, "a/one.txt", "same\nlines\n")
    write(oracle, "a/two.png", make_png)
    write(current, "a/two.png", make_png([1, 0] => ChunkyPNG::Color.rgb(0, 255, 0)))
    write(oracle, "b/deep.html", "<div id=\"x\" class=\"a\"><p>hello</p></div>")
    write(current, "b/deep.html", "<div class=\"a\"\n     id=\"x\">\n  <p>hello</p>\n</div>\n")
    write(oracle, "c/odd.xyz", "???")
    write(current, "c/odd.xyz", "???")
    write(oracle, "d/only-oracle.txt", "gone")
    write(current, "e/only-current.txt", "extra")

    config_path = File.join(tmp, "twinshot.yml")
    File.write(config_path, <<~YAML)
      oracle:
        path: #{oracle}
      current:
        path: #{current}
    YAML
    Twinshot::Config.load(config_path)
  end

  def write(root, rel, content)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    content = content.b if rel.end_with?(".png")
    File.binwrite(path, content)
  end

  def make_png(changed = {})
    image = ChunkyPNG::Image.new(2, 2, ChunkyPNG::Color.rgb(255, 0, 0))
    changed.each { |(x, y), color| image[x, y] = color }
    StringIO.open { |io| image.write(io); io.string }
  end
end
