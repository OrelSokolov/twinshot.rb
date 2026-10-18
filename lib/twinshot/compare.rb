# frozen_string_literal: true

require "etc"
require "json"
require "tmpdir"

module Twinshot
  # Orchestrates a compare run: structure check first (cheap, sequential),
  # then every common file through its adapter — optionally in a pool of
  # forked worker processes (chunky_png pixel walks are CPU-bound, so real
  # processes beat threads under the GVL; works on any unix ruby >= 3.2).
  class Compare
    class Error < StandardError; end

    MAX_WORKERS = 8

    def initialize(config)
      @config = config
    end

    # Returns the summary hash: { "total", "passed", "failed", "results" }.
    def run(jobs: nil)
      oracle_files = scan(@config.oracle_path, "oracle")
      current_files = scan(@config.current_path, "current")
      structure = Tree.diff(oracle_files, current_files)
      results = structure_results(structure)

      common = oracle_files - structure["missing"]
      entries = common.to_h { |rel| [rel, Adapters.for(rel)] }
      results.concat(entries.filter_map { |rel, adapter| unknown_result(rel) if adapter.nil? })

      comparable = entries.select { |_rel, adapter| adapter }
      workers = resolve_workers(jobs, comparable.size)
      results.concat(workers > 1 ? parallel(comparable, workers) : sequential(comparable))
      summarize(results)
    end

    private

    def scan(path, side)
      Tree.files(path)
    rescue Errno::ENOENT
      raise Config::Error, "#{side} path not found: #{path}"
    end

    def structure_results(structure)
      structure["missing"].map do |rel|
        { "rel" => rel, "kind" => "structure", "status" => "fail", "detail" => "missing in current" }
      end + structure["extra"].map do |rel|
        { "rel" => rel, "kind" => "structure", "status" => "fail",
          "detail" => "extra in current (not in oracle)" }
      end
    end

    def unknown_result(rel)
      { "rel" => rel, "kind" => "unknown", "status" => "fail",
        "detail" => "no adapter for #{File.extname(rel)}" }
    end

    def ctx
      Adapters::Ctx.new(max_diff_ratio: @config.max_diff_ratio, report_dir: @config.report_dir)
    end

    def sequential(entries)
      entries.map { |rel, adapter| run_one(rel, adapter) }
    end

    def run_one(rel, adapter)
      result = adapter.call(rel, File.join(@config.oracle_path, rel),
                            File.join(@config.current_path, rel), ctx)
      result.merge("rel" => rel)
    rescue StandardError => e
      { "rel" => rel, "kind" => "error", "status" => "fail", "detail" => "#{e.class}: #{e.message}" }
    end

    def parallel(entries, workers)
      Dir.mktmpdir("twinshot") do |tmp|
        result_files = Array.new(workers) { |i| File.join(tmp, "results-#{i}.json") }
        pids = Array.new(workers) do |i|
          fork_worker(entries, workers, i, result_files[i])
        end
        crashed = pids.map do |pid|
          Process.wait(pid)
          !$?.success?
        end.any?
        raise Error, "a compare worker crashed" if crashed

        result_files.flat_map { |file| JSON.parse(File.read(file)) }
      end
    end

    def fork_worker(entries, workers, index, result_file)
      Process.fork do
        slice = entries.select.with_index { |_entry, i| i % workers == index }
        results = slice.map { |rel, adapter| run_one(rel, adapter) }
        File.open(result_file, "w") { |io| io.write(JSON.generate(results)) }
        exit!(0) # skip parent's at_exit handlers
      end
    end

    def resolve_workers(jobs, work_size)
      return 1 if work_size < 2
      return 1 if jobs && jobs <= 1

      [jobs || Etc.nprocessors, MAX_WORKERS, work_size].min
    end

    def summarize(results)
      sorted = results.sort_by do |r|
        [File.dirname(r["rel"]), r["status"] == "pass" ? 1 : 0, File.basename(r["rel"])]
      end
      {
        "total" => sorted.size,
        "passed" => sorted.count { |r| r["status"] == "pass" },
        "failed" => sorted.count { |r| r["status"] == "fail" },
        "results" => sorted
      }
    end
  end
end
