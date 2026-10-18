# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "vips"

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
      report_html = File.read(File.join(config.report_dir, Twinshot::Config::HUMAN_REPORT))
      assert_includes report_html, %(data-name="a/two.png")
      assert_includes report_html, %(data-name="e/only-current.txt")
      agent_md = File.read(File.join(config.report_dir, Twinshot::Config::AGENT_REPORT))
      assert_includes agent_md, "### a/two.png"
      assert_includes agent_md, "- oracle: #{File.join(config.oracle_path, 'a/two.png')}"
      assert_includes agent_md, "- current: #{File.join(config.current_path, 'a/two.png')}"
      assert_includes agent_md, "### d/only-oracle.txt"
      assert_includes agent_md, "- oracle: #{File.join(config.oracle_path, 'd/only-oracle.txt')}"
      assert_includes agent_md, "## Passed (2)"
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

  def test_multiple_groups_tag_results_and_reports
    Dir.mktmpdir do |tmp|
      config = build_fixture(tmp)
      config_path = File.join(tmp, "twinshot.yml")
      File.write(config_path, File.read(config_path) + <<~YAML)
        groups:
          dogs:
            oracle: {path: #{File.join(tmp, 'dogs-o')}}
            current: {path: #{File.join(tmp, 'dogs-c')}}
      YAML
      write(File.join(tmp, "dogs-o"), "bark.txt", "woof\n")
      write(File.join(tmp, "dogs-c"), "bark.txt", "meow\n")
      config = Twinshot::Config.load(config_path)

      summary = Twinshot::Compare.new(config).run(jobs: 1)
      Twinshot::Report.new(config, summary).write

      assert_equal %w[default dogs], summary["groups"].map { |g| g["name"] }
      dogs = summary["results"].select { |r| r["group"] == "dogs" }
      assert_equal 1, dogs.size
      assert_equal "fail", dogs.first["status"]
      assert_equal "default", summary["results"].find { |r| r["rel"] == "a/one.txt" }["group"]

      default_dir = File.join(tmp, "twinshot-report", "default")
      dogs_dir = File.join(tmp, "twinshot-report", "dogs")
      assert File.exist?(File.join(default_dir, Twinshot::Config::HUMAN_REPORT))
      assert File.exist?(File.join(default_dir, "diffs", "a", "two.png.diff.png"))
      dogs_html = File.read(File.join(dogs_dir, Twinshot::Config::HUMAN_REPORT))
      assert_includes dogs_html, %(data-name="bark.txt")
      assert_includes dogs_html, "dogs"
      refute_includes dogs_html, %(data-name="a/one.txt")
      dogs_md = File.read(File.join(dogs_dir, Twinshot::Config::AGENT_REPORT))
      assert_includes dogs_md, "### bark.txt"
      assert_includes dogs_md, "````diff"
      assert_includes dogs_md, "-woof"
      assert_includes dogs_md, "+meow"
      refute_includes dogs_md, "a/one.txt"
      dogs_summary = JSON.parse(File.read(File.join(dogs_dir, "summary.json")))
      assert_equal 1, dogs_summary["total"]
      assert_equal "dogs", dogs_summary["results"].first["group"]
    end
  end

  private

  def build_fixture(tmp)
    oracle = File.join(tmp, "oracle")
    current = File.join(tmp, "current")
    write(oracle, "a/one.txt", "same\nlines\n")
    write(current, "a/one.txt", "same\nlines\n")
    write(oracle, "a/two.png", make_png)
    write(current, "a/two.png", make_png([1, 0] => [0, 255, 0]))
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
    image = Vips::Image.black(2, 2, bands: 3).add([255, 0, 0])
    changed.each { |(x, y), color| image = image.draw_rect(color, x, y, 1, 1) }
    image.pngsave_buffer
  end
end
