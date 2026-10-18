# frozen_string_literal: true

require "chunky_png"
require "digest"
require "fileutils"

module Twinshot
  module Adapters
    # PNG: bytes fast-path, then pixel-by-pixel. Pass when the share of
    # differing pixels is within ctx.max_diff_ratio. On fail writes a diff
    # image (differing pixels painted red over the current snapshot) into
    # the report dir. Whenever any pixel differs, also emits "heat" — a
    # grid metadata for the report's purple overlay (see #heat_grid).
    module Png
      module_function

      HEAT_CELL = 32

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
        if diff_indexes.any?
          result["heat"] = heat_grid(a, diff_indexes)
          if result["status"] == "fail"
            result["diff_image"] = write_diff_image(rel, b, diff_indexes, ctx)
          end
        end
        result
      end

      def decode(path)
        ChunkyPNG::Image.from_file(path)
      rescue ChunkyPNG::Exception => e
        { "kind" => "png", "image" => true, "status" => "fail", "detail" => "decode error: #{e.message}" }
      end

      # Splits the image into HEAT_CELL squares and returns, for every cell
      # with at least one differing pixel, its share of differing pixels:
      #
      #   { "cell" => 32, "w" => 1280, "h" => 800,
      #     "cells" => [[col, row, intensity], ...] }  # intensity in 0..1
      #
      # Edge cells on the right/bottom cover the remainder, so their area
      # (the intensity denominator) is smaller than HEAT_CELL^2.
      def heat_grid(image, diff_indexes)
        cols = (image.width + HEAT_CELL - 1) / HEAT_CELL
        counts = Array.new(cols * ((image.height + HEAT_CELL - 1) / HEAT_CELL), 0)
        diff_indexes.each do |i|
          counts[(i / image.width / HEAT_CELL) * cols + ((i % image.width) / HEAT_CELL)] += 1
        end
        cells = counts.each_with_index.filter_map do |count, idx|
          next if count.zero?

          col = idx % cols
          row = idx / cols
          width = [image.width - col * HEAT_CELL, HEAT_CELL].min
          height = [image.height - row * HEAT_CELL, HEAT_CELL].min
          [col, row, (count.fdiv(width * height) * 100).round / 100.0]
        end
        { "cell" => HEAT_CELL, "w" => image.width, "h" => image.height, "cells" => cells }
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
