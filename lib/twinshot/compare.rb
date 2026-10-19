# frozen_string_literal: true

require "etc"
require "json"
require "rbconfig"

module Twinshot
  # Orchestrates a compare run: structure check first (cheap, sequential),
  # then every common file through its adapter — in a pool of worker
  # processes (libvips pixel compares are CPU-bound, so real processes beat
  # threads under the GVL). Workers are fresh rubies exec'd via
  # compare_worker.rb (~0.13s boot, in parallel): forking this process
  # instead would be free, but once it has run any libvips operation
  # (sequential group, fixtures, library usage) forked children can
  # deadlock on their first image compare — idle libvips worker threads
  # leave glib state that does not survive fork.
  #
  # Every configured group runs through the same pipeline in config order;
  # each produced result carries its group name, and diff artifacts land in
  # that group's report folder.
  #
  # Workers stream each finished result to the parent over a dedicated pipe
  # (one pipe per worker, one JSON line per result), so progress callbacks
  # fire in real time instead of after the whole run.
  class Compare
    class Error < StandardError; end

    # A spawned worker: read its JSON result lines from #reader, then #finish
    # (after drain saw EOF) and #crashed? to reap it.
    Worker = Struct.new(:reader, :pid) do
      def finish
        reader.close unless reader.closed?
      end

      def crashed?
        Process.wait(pid)
        !Process.last_status.success?
      end
    end

    MAX_WORKERS = 8

    def initialize(config)
      @config = config
    end

    # Returns the summary hash: { "total", "passed", "warned", "failed",
    # "groups", "results" } — groups holds per-group stats plus the relative path to
    # that group's report. progress (Twinshot::Progress or anything
    # responding to #banner/#result) is optional; every produced result is
    # announced to it in arrival order. groups limits the run to a subset of
    # the configured ones (default: all, in config order).
    def run(jobs: nil, progress: nil, groups: nil)
      groups ||= @config.groups
      results = []
      group_stats = groups.map do |group|
        group_results = run_group(group, jobs, progress)
        results.concat(group_results)
        {
          "name" => group.name,
          "total" => group_results.size,
          "passed" => group_results.count { |r| r["status"] == "pass" },
          "warned" => group_results.count { |r| r["status"] == "warn" },
          "failed" => group_results.count { |r| r["status"] == "fail" },
          "report" => File.join(Config::REPORT_DIRNAME, group.name, Config::HUMAN_REPORT)
        }
      end
      summarize(results, group_stats)
    end

    private

    def run_group(group, jobs, progress)
      oracle_files = scan(group, "oracle")
      current_files = scan(group, "current")
      structure = Tree.diff(oracle_files, current_files)
      # soft_check entries may legitimately exist on only one side (oracle or
      # current): their missing/extra results are downgraded to warns in
      # structure_results below, and they are never content-compared — a file
      # on a single side has no pair to compare. Present on both sides, the
      # content diff downgrades to a warn in soften/compare_worker.rb.
      common = oracle_files & current_files
      entries = common.to_h { |rel| [rel, Adapters.for(rel)] }
      unknown = entries.filter_map { |rel, adapter| unknown_result(group, rel) if adapter.nil? }
      comparable = entries.select { |_rel, adapter| adapter }
      workers = resolve_workers(jobs, comparable.size)
      total = common.size + structure["missing"].size + structure["extra"].size
      ctx = Adapters::Ctx.new(max_diff_ratio: @config.max_diff_ratio, report_dir: @config.report_dir(group))

      progress&.banner(@config, group: group, oracle_count: oracle_files.size, current_count: current_files.size,
                                total: total, workers: workers)
      results = []
      structure_results(group, structure).each do |r|
        results << r
        progress&.result(r)
      end
      unknown.each do |r|
        results << r
        progress&.result(r)
      end

      file_results = if workers > 1
                       parallel(group, ctx, comparable, workers, progress)
                     else
                       sequential(group, ctx, comparable, progress)
                     end
      results.concat(file_results)
    end

    def scan(group, side)
      path = side == "oracle" ? group.oracle_path : group.current_path
      Tree.files(path)
    rescue Errno::ENOENT
      raise Config::Error, "#{side} path not found for group #{group.name}: #{path}"
    end

    # Structure results keep their missing/extra detail, but soft_check
    # entries are warnings, not failures — a listed file may legitimately
    # exist on only one side.
    def structure_results(group, structure)
      soften_structure = ->(rel) { @config.soft_check?(rel) ? "warn" : "fail" }
      structure["missing"].map do |rel|
        { "group" => group.name, "rel" => rel, "kind" => "structure", "status" => soften_structure.call(rel),
          "detail" => "missing in current" }
      end + structure["extra"].map do |rel|
        { "group" => group.name, "rel" => rel, "kind" => "structure", "status" => soften_structure.call(rel),
          "detail" => "extra in current (not in oracle)" }
      end
    end

    def unknown_result(group, rel)
      { "group" => group.name, "rel" => rel, "kind" => "unknown", "status" => "fail",
        "detail" => "no adapter for #{File.extname(rel)}" }
    end

    def sequential(group, ctx, entries, progress)
      entries.map do |rel, adapter|
        run_one(group, ctx, rel, adapter).tap { |r| progress&.result(r) }
      end
    end

    def run_one(group, ctx, rel, adapter)
      result = adapter.call(rel, File.join(group.oracle_path, rel),
                            File.join(group.current_path, rel), ctx)
      soften(result, rel)
      result.merge("rel" => rel, "group" => group.name)
    rescue StandardError => e
      { "group" => group.name, "rel" => rel, "kind" => "error", "status" => "fail",
        "detail" => "#{e.class}: #{e.message}" }
    end

    # soft_check paths tolerate content diffs: fail → warn, so the run stays
    # green while the reports still show the diff. Mirrored in
    # compare_worker.rb. Adapter crashes (kind "error") are not softened —
    # that is not "the time changed".
    def soften(result, rel)
      result["status"] = "warn" if result["status"] == "fail" && @config.soft_check?(rel)
    end

    def parallel(group, ctx, entries, workers, progress)
      spawned = spawn_workers(group, ctx, entries, workers)
      results = drain(spawned.map(&:reader), progress)
      spawned.each(&:finish)
      crashed = spawned.any?(&:crashed?)
      raise Error, "a compare worker crashed" if crashed
      raise Error, "workers produced #{results.size}/#{entries.size} results" if results.size != entries.size

      results
    end

    def spawn_workers(group, ctx, entries, workers)
      script = File.expand_path("compare_worker.rb", __dir__)
      libdir = File.expand_path("..", __dir__)
      base = {
        "group" => group.name,
        "oracle" => group.oracle_path,
        "current" => group.current_path,
        "max_diff_ratio" => ctx.max_diff_ratio,
        "report_dir" => ctx.report_dir,
        "soft_check" => @config.soft_check,
        "rels" => entries.map(&:first)
      }
      Array.new(workers) do |index|
        payload_rd, payload_wr = IO.pipe
        out_rd, out_wr = IO.pipe
        pid = Process.spawn(RbConfig.ruby, "-I", libdir, script, in: payload_rd, out: out_wr)
        payload_wr.write(JSON.generate(base.merge("index" => index, "workers" => workers)))
        payload_rd.close
        payload_wr.close
        out_wr.close
        Worker.new(out_rd, pid)
      end
    end

    # Read newline-delimited JSON results from all worker pipes until every
    # writer exits, announcing each result to progress as it arrives.
    def drain(readers, progress)
      results = []
      buffers = {}
      readers.each { |rd| buffers[rd] = +"" }
      until readers.empty?
        ready, = IO.select(readers)
        ready.each do |io|
          chunk = io.read_nonblock(65_536, exception: false)
          case chunk
          when :wait_readable then next
          when nil, :eof # ruby 4.0 returns nil at EOF with exception: false
            readers.delete(io)
            io.close
          else
            buffer = buffers[io] << chunk
            while (newline = buffer.index("\n"))
              line = buffer.slice!(0..newline)
              result = JSON.parse(line)
              results << result
              progress&.result(result)
            end
          end
        end
      end
      results
    end

    def resolve_workers(jobs, work_size)
      return 1 if work_size < 2
      return 1 if jobs && jobs <= 1

      [jobs || Etc.nprocessors, MAX_WORKERS, work_size].min
    end

    def summarize(results, group_stats)
      order = group_stats.each_with_index.to_h { |g, i| [g["name"], i] }
      # fail first, then warn, then pass — the statuses the report is opened
      # for lead their directory.
      rank = { "fail" => 0, "warn" => 1 }
      sorted = results.sort_by do |r|
        [order[r["group"]], File.dirname(r["rel"]), rank.fetch(r["status"], 2), File.basename(r["rel"])]
      end
      {
        "total" => sorted.size,
        "passed" => sorted.count { |r| r["status"] == "pass" },
        "warned" => sorted.count { |r| r["status"] == "warn" },
        "failed" => sorted.count { |r| r["status"] == "fail" },
        "groups" => group_stats,
        "results" => sorted
      }
    end
  end
end
