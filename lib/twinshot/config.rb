# frozen_string_literal: true

require "yaml"

module Twinshot
  # Minimal twinshot.yml:
  #
  #   oracle:  { path: artifacts/rails,  generate: bin/record }
  #   current: { path: artifacts/crails, generate: bin/record --crails }
  #   png:     { max_diff_ratio: 0.002 }
  #
  # The report always lands in <dirname(config)>/twinshot-report/ — not configurable.
  class Config
    class Error < StandardError; end

    DEFAULT_FILENAME = "twinshot.yml"
    DEFAULT_MAX_DIFF_RATIO = 0.002
    REPORT_DIRNAME = "twinshot-report"
    SIDES = %w[oracle current].freeze

    attr_reader :path, :root

    def self.load(path = nil)
      path = File.expand_path(path || DEFAULT_FILENAME)
      raise Error, "config not found: #{path}" unless File.file?(path)

      data = begin
        YAML.safe_load(File.read(path), aliases: true) || {}
      rescue Psych::SyntaxError => e
        raise Error, "invalid YAML in #{path}: #{e.message}"
      end
      new(path, data)
    end

    def initialize(path, data)
      @path = path
      @root = File.dirname(path)
      @data = data
      validate!
    end

    def oracle_path
      side_path("oracle")
    end

    def current_path
      side_path("current")
    end

    def generate_command(side)
      unless SIDES.include?(side)
        raise Error, "unknown side: #{side.inspect} (expected oracle or current)"
      end

      value = @data.dig(side, "generate")
      case value
      when nil then nil
      when String then value
      else raise Error, "#{side}.generate must be a shell command string"
      end
    end

    def max_diff_ratio
      value = @data.dig("png", "max_diff_ratio") || DEFAULT_MAX_DIFF_RATIO
      Float(value)
    rescue ArgumentError, TypeError
      raise Error, "png.max_diff_ratio must be a number, got: #{value.inspect}"
    end

    def report_dir
      File.join(@root, REPORT_DIRNAME)
    end

    private

    def side_path(side)
      value = @data.dig(side, "path")
      unless value.is_a?(String) && !value.empty?
        raise Error, "#{side}.path is required in #{File.basename(@path)}"
      end

      File.expand_path(value, @root)
    end

    def validate!
      raise Error, "config root must be a mapping" unless @data.is_a?(Hash)

      @data.each do |key, value|
        raise Error, "#{key} must be a mapping" if key != "png" && !value.is_a?(Hash)
      end
      oracle_path
      current_path
      max_diff_ratio
    end
  end
end
