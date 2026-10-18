# frozen_string_literal: true

require "etc"
require "json"

module Twinshot
  # Orchestrates a compare run: structure check first (cheap, sequential),
  # then every common file through its adapter — optionally in a pool of
  # forked worker processes (chunky_png pixel walks are CPU-bound, so real
  # processes beat threads under the GVL; works on any unix ruby >= 3.2).
  #
  # Workers stream each finished result to the parent over a dedicated pipe
  # (one pipe per worker, one JSON line per result), so progress callbacks
  # fire in real time instead of after the whole run.
  class Compare
    class Error < StandardError; end

    MAX_WORKERS = 8

    def initialize(config)
      @config = config
    end

    # Returns the summary hash: { "total", "passed", "failed", "results" }.
    # progress (Twinshot::Progress or anything responding to #banner/#result)
    # is optional; every produced result is announced to it in arrival order.
    def run(jobs: nil, progress: nil)
      oracle_files = scan(@config.oracle_path, "oracle")
      current_files = scan(@config.current_path, "current")
      structure = Tree.diff(oracle_files, current_files)
      common = oracle_files - structure["missing"]
      entries = common.to_h { |rel| [rel, Adapters.for(rel)] }
      unknown = entries.filter_map { |rel, adapter| unknown_result(rel) if adapter.nil? }
      comparable = entries.select { |_rel, adapter| adapter }
      workers = resolve_workers(jobs, comparable.size)
      total = oracle_files.size + structure["extra"].size

      progress&.banner(@config, oracle_count: oracle_files.size, current_count: current_files.size,
                                total: total, workers: workers)
      results = []
      structure_results(structure).each { |r| results << r; progress&.result(r) }
      unknown.each { |r| results << r; progress&.result(r) }

      file_results = if workers > 1
                       parallel(comparable, workers, progress)
                     else
                       sequential(comparable, progress)
                     end
      results.concat(file_results)
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

    def sequential(entries, progress)
      entries.map do |rel, adapter|
        run_one(rel, adapter).tap { |r| progress&.result(r) }
      end
    end

    def run_one(rel, adapter)
      result = adapter.call(rel, File.join(@config.oracle_path, rel),
                            File.join(@config.current_path, rel), ctx)
      result.merge("rel" => rel)
    rescue StandardError => e
      { "rel" => rel, "kind" => "error", "status" => "fail", "detail" => "#{e.class}: #{e.message}" }
    end

    def parallel(entries, workers, progress)
      pipes = Array.new(workers) { IO.pipe }
      pids = spawn_workers(pipes, entries, workers)
      pipes.each { |_rd, wr| wr.close }
      results = drain(pipes.map(&:first), progress)
      crashed = pids.map do |pid|
        Process.wait(pid)
        !$?.success?
      end.any?
      raise Error, "a compare worker crashed" if crashed
      raise Error, "workers produced #{results.size}/#{entries.size} results" if results.size != entries.size

      results
    end

    def spawn_workers(pipes, entries, workers)
      pipes.each_with_index.map do |(_rd, wr), index|
        Process.fork do
          pipes.each { |rd, _wr| rd.close }
          wr.sync = true
          entries.select.with_index { |_entry, i| i % workers == index }.each do |rel, adapter|
            wr.write(JSON.generate(run_one(rel, adapter)) + "\n")
          end
          exit!(0) # skip parent's at_exit handlers
        end
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
