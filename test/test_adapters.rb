# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "chunky_png"

class TestAdapters < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("twinshot-adapter")
    @ctx = Twinshot::Adapters::Ctx.new(max_diff_ratio: 0.0, report_dir: File.join(@tmp, "report"))
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_registry_lookup
    refute_nil Twinshot::Adapters.for("a/b.PNG")
    refute_nil Twinshot::Adapters.for("page.html")
    refute_nil Twinshot::Adapters.for("note.txt")
    refute_nil Twinshot::Adapters.for("blob.bin")
    assert_nil Twinshot::Adapters.for("mystery.weird")
  end

  def test_binary
    assert_equal "pass", call(Twinshot::Adapters::Binary, "x", "x")["status"]
    assert_equal "fail", call(Twinshot::Adapters::Binary, "x", "y")["status"]
  end

  def test_txt_pass_and_line_diff
    result = call(Twinshot::Adapters::Txt, "one\ntwo\n", "one\ntwo\n")
    assert_equal "pass", result["status"]

    result = call(Twinshot::Adapters::Txt, "one\ntwo\n", "one\nTWO\n")
    assert_equal "fail", result["status"]
    assert_equal 2, result["diff_lines"]
    types = result["diff"].map { |e| e["t"] }
    assert_includes types, "del"
    assert_includes types, "add"
  end

  def test_txt_ignores_line_ending_differences
    assert_equal "pass", call(Twinshot::Adapters::Txt, "a\r\nb\r\n", "a\nb\n")["status"]
  end

  def test_html_structure_identical_despite_whitespace_and_attr_order
    a = %(<!doctype html><html><body><div class="a" id="x"><p>hello  world</p></div></body></html>)
    b = <<~HTML
      <html>
        <body>
          <div id="x" class="a">
            <p>hello world</p>
          </div>
        </body>
      </html>
    HTML
    assert_equal "pass", call(Twinshot::Adapters::Html, a, b)["status"]
  end

  def test_html_structure_differs_on_missing_element
    a = "<div><p>one</p><p>two</p></div>"
    b = "<div><p>one</p></div>"
    result = call(Twinshot::Adapters::Html, a, b)
    assert_equal "fail", result["status"]
    assert_predicate result["diff_lines"], :positive?
  end

  def test_png_bytes_equal_fast_path
    png = make_png("red")
    assert_equal "pass", call(Twinshot::Adapters::Png, png, png)["status"]
  end

  def test_png_pixel_diff_and_threshold
    a = make_png("red")
    b = make_png_with_pixel("red", 1, 0, ChunkyPNG::Color.rgb(0, 255, 0))
    result = call(Twinshot::Adapters::Png, a, b)
    assert_equal "fail", result["status"] # ctx threshold is 0.0
    assert_equal 0.25, result["ratio"]
    assert File.exist?(File.join(@ctx.report_dir, result["diff_image"]))

    lenient = Twinshot::Adapters::Ctx.new(max_diff_ratio: 0.5, report_dir: @ctx.report_dir)
    result = Twinshot::Adapters::Png.call("a.png", write_file("a.png", a), write_file("b.png", b), lenient)
    assert_equal "pass", result["status"]
  end

  def test_png_size_mismatch
    wide = make_png("red")
    tall = make_png("red", height: 3)
    result = call(Twinshot::Adapters::Png, wide, tall)
    assert_equal "fail", result["status"]
    assert_match(/size mismatch 2x2 vs 2x3/, result["detail"])
  end

  private

  def call(adapter, oracle_content, current_content)
    adapter.call("f", write_file("oracle", oracle_content), write_file("current", current_content), @ctx)
  end

  def write_file(name, content)
    path = File.join(@tmp, name)
    File.binwrite(path, content)
    path
  end

  def make_png(color, width: 2, height: 2)
    rgb = { "red" => [255, 0, 0] }.fetch(color)
    image = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color.rgb(*rgb))
    StringIO.open { |io| image.write(io); io.string }
  end

  def make_png_with_pixel(color, x, y, pixel)
    image = ChunkyPNG::Image.new(2, 2, ChunkyPNG::Color.rgb(*{ "red" => [255, 0, 0] }.fetch(color)))
    image[x, y] = pixel
    StringIO.open { |io| image.write(io); io.string }
  end
end
