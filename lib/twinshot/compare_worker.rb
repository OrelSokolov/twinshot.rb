# frozen_string_literal: true

# Exec'd compare worker. Compare's worker pool is a set of fresh rubies
# running this script: forking the parent would be free, but once it has run
# any libvips operation (sequential group, fixtures, library usage) forked
# children can deadlock on their first image compare — idle libvips worker
# threads leave glib state that does not survive fork.
#
# Reads one JSON blob on stdin:
#
#   { "group": "default", "oracle": "...", "current": "...", "rels": ["a.png"],
#     "max_diff_ratio": 0.002, "report_dir": "...", "index": 0, "workers": 4 }
#
# and writes one JSON result line per its slice of rels to stdout — the same
# protocol the forked workers use. Result construction mirrors
# Compare#run_one; keep the two in sync.

require "json"
require_relative "adapters"

payload = JSON.parse($stdin.read)
ctx = Twinshot::Adapters::Ctx.new(max_diff_ratio: payload.fetch("max_diff_ratio"),
                                  report_dir: payload.fetch("report_dir"))
group = payload.fetch("group")
oracle = payload.fetch("oracle")
current = payload.fetch("current")
index = payload.fetch("index")
workers = payload.fetch("workers")
$stdout.sync = true

payload.fetch("rels").each_with_index do |rel, i|
  next unless i % workers == index

  result = begin
    Twinshot::Adapters.for(rel).call(rel, File.join(oracle, rel), File.join(current, rel), ctx)
                      .merge("rel" => rel, "group" => group)
  rescue StandardError => e
    { "group" => group, "rel" => rel, "kind" => "error", "status" => "fail",
      "detail" => "#{e.class}: #{e.message}" }
  end
  $stdout.write("#{JSON.generate(result)}\n")
end
