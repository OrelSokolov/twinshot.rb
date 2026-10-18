# frozen_string_literal: true

require "digest"
require "fileutils"
require "vips"

# twinshot parallelizes across files with its own worker pool, so keep each
# libvips call single-threaded — otherwise every forked worker would spin up
# its own nproc-sized libvips threadpool and oversubscribe the machine.
Vips.vips_concurrency_set(1)

module Twinshot
  module Adapters
    # PNG: bytes fast-path, then pixel-by-pixel via libvips (decode, diff mask
    # and diff image are all native C — a pure-ruby pixel walk was the old
    # bottleneck). Pass when the share of differing pixels is within
    # ctx.max_diff_ratio. On fail writes a diff image (differing pixels painted
    # red over the current snapshot) into the report dir. Whenever any pixel
    # differs, also emits "heat" — a grid metadata for the report's purple
    # overlay (see #heat_grid).
    module Png
      module_function

      HEAT_CELL = 32
      RED = [255, 0, 0, 255].freeze

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

        mask = diff_mask(a, b).copy_memory
        total = a.width * a.height
        diff_count = (mask.avg * total / 255.0).round
        ratio = diff_count.fdiv(total)
        result = { "kind" => "png", "image" => true,
                   "status" => ratio <= ctx.max_diff_ratio ? "pass" : "fail",
                   "detail" => format("%.3f%% px differ (%d/%d)", ratio * 100, diff_count, total),
                   "ratio" => ratio }
        if diff_count.positive?
          result["heat"] = heat_grid(a, mask)
          if result["status"] == "fail"
            result["diff_image"] = write_diff_image(rel, b, mask, ctx)
          end
        end
        result
      end

      def decode(path)
        Vips::Image.new_from_file(path, access: :random)
      rescue Vips::Error => e
        { "kind" => "png", "image" => true, "status" => "fail", "detail" => "decode error: #{e.message}" }
      end

      # Single-band 0/255 mask: 255 where any band of the two images differs.
      # Both sides are normalized to rgba first so an rgb/rgba (or grey/rgba)
      # pair still compares pixel-wise.
      def diff_mask(a, b)
        (rgba(a) != rgba(b)).bandor
      end

      def rgba(img)
        case img.bands
        when 1 then g = img.extract_band(0); g.bandjoin([g, g]).bandjoin_const([255])
        when 2 then g = img.extract_band(0); g.bandjoin([g, g, img.extract_band(1)])
        when 3 then img.bandjoin_const([255])
        else img
        end
      end

      # Splits the image into HEAT_CELL squares and returns, for every cell
      # with at least one differing pixel, its share of differing pixels:
      #
      #   { "cell" => 32, "w" => 1280, "h" => 800,
      #     "cells" => [[col, row, intensity], ...] }  # intensity in 0..1
      #
      # Per-cell differing-pixel counts come from a libvips shrink (average
      # over each cell) so the counting stays native. Edge cells on the
      # right/bottom cover the remainder, so their area (the intensity
      # denominator) is smaller than HEAT_CELL^2.
      def heat_grid(image, mask)
        width = image.width
        height = image.height
        cols = (width + HEAT_CELL - 1) / HEAT_CELL
        rows = (height + HEAT_CELL - 1) / HEAT_CELL
        # pad to a HEAT_CELL multiple so shrink keeps whole cells (and works
        # at all when the image is smaller than one cell); the zero padding
        # leaves each cell's differing-pixel count untouched.
        padded = mask.embed(0, 0, cols * HEAT_CELL, rows * HEAT_CELL)
        avgs = padded.cast(:float).shrink(HEAT_CELL, HEAT_CELL).write_to_memory.unpack("e*")
        cells = avgs.each_with_index.filter_map do |avg, idx|
          col = idx % cols
          row = idx / cols
          cell_w = [width - col * HEAT_CELL, HEAT_CELL].min
          cell_h = [height - row * HEAT_CELL, HEAT_CELL].min
          # avg is over the padded HEAT_CELL^2 cell, so the count denominator
          # is the padded area, not the cell's actual (edge-trimmed) area.
          count = (avg * HEAT_CELL * HEAT_CELL / 255.0).round
          next if count.zero?

          [col, row, (count.fdiv(cell_w * cell_h) * 100).round / 100.0]
        end
        { "cell" => HEAT_CELL, "w" => width, "h" => height, "cells" => cells }
      end

      def write_diff_image(rel, base, mask, ctx)
        diff = mask.ifthenelse(RED, rgba(base))
        rel_path = File.join("diffs", "#{rel}.diff.png")
        abs = File.join(ctx.report_dir, rel_path)
        FileUtils.mkdir_p(File.dirname(abs))
        diff.pngsave(abs)
        rel_path
      end
    end

    register(Png, "png")
  end
end
