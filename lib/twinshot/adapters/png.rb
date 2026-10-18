# frozen_string_literal: true

require "chunky_png"
require "digest"
require "fileutils"

module Twinshot
  module Adapters
    # PNG: bytes fast-path, then pixel-by-pixel. Pass when the share of
    # differing pixels is within ctx.max_diff_ratio. On fail writes a diff
    # image (differing pixels painted red over the current snapshot) into
    # the report dir.
    module Png
      module_function

      def call(rel, oracle_file, current_file, ctx)
        if Digest::SHA256.file(oracle_file).hexdigest == Digest::SHA256.file(current_file).hexdigest
          return { "kind" => "png", "image" => true, "status" => "pass", "detail" => "bytes equal" }
        end

        a = decode(oracle_file)
        b = decode(current_file)
        return a if a.is_a?(Hash)
        return b if b.is_a?(Hash)
        if a.width != b.width || a.height != b.height
          return { "kind" => "png", "image" => true, "status" => "fail",
                   "detail" => "size mismatch #{a.width}x#{a.height} vs #{b.width}x#{b.height}" }
        end

        a_pixels = a.pixels
        b_pixels = b.pixels
        diff_indexes = []
        a_pixels.each_index { |i| diff_indexes << i if a_pixels[i] != b_pixels[i] }
        ratio = diff_indexes.size.fdiv(a_pixels.size)
        result = { "kind" => "png", "image" => true,
                   "status" => ratio <= ctx.max_diff_ratio ? "pass" : "fail",
                   "detail" => format("%.3f%% px differ (%d/%d)", ratio * 100, diff_indexes.size, a_pixels.size),
                   "ratio" => ratio }
        if diff_indexes.any? && result["status"] == "fail"
          result["diff_image"] = write_diff_image(rel, b, diff_indexes, ctx)
        end
        result
      end

      def decode(path)
        ChunkyPNG::Image.from_file(path)
      rescue ChunkyPNG::Exception => e
        { "kind" => "png", "image" => true, "status" => "fail", "detail" => "decode error: #{e.message}" }
      end

      def write_diff_image(rel, base, diff_indexes, ctx)
        diff = ChunkyPNG::Image.new(base.width, base.height, base.pixels.dup)
        red = ChunkyPNG::Color.rgb(255, 0, 0)
        diff_indexes.each { |i| diff.pixels[i] = red }
        rel_path = File.join("diffs", "#{rel}.diff.png")
        abs = File.join(ctx.report_dir, rel_path)
        FileUtils.mkdir_p(File.dirname(abs))
        diff.save(abs)
        rel_path
      end
    end

    register(Png, "png")
  end
end
