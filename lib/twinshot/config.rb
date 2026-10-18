# frozen_string_literal: true

require "yaml"

module Twinshot
  # Minimal twinshot.yml:
  #
  #   oracle:  { path: artifacts/rails,  generate: bin/record }
  #   current: { path: artifacts/crails, generate: bin/record --crails }
  #   png:     { max_diff_ratio: 0.002 }
  #   groups:
  #     dogs:
  #       oracle:  { path: artifacts/dogs-rails }
  #       current: { path: artifacts/dogs-crails }
  #
  # The top-level oracle/current pair is the unnamed default group; groups:
  # adds named groups (arbitrary names) with the same shape. Each group gets
  # its own report folder twinshot-report/<name>/ — not configurable.
  class Config
    class Error < StandardError; end

    # A named pair of artifact trees: oracle/current paths plus optional
    # generate commands. label prefixes error messages ("" for the default
    # group, "groups.<name>" for named ones).
    class Group
      attr_reader :name, :data, :root, :label

      def initialize(name, data, root, file, label)
        @name = name
        @data = data
        @root = root
        @file = file
        @label = label
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
        else raise Error, "#{prefix}#{side}.generate must be a shell command string"
        end
      end

      def validate!
        raise Error, "#{label.empty? ? 'group' : label} must be a mapping" unless @data.is_a?(Hash)

        oracle_path
        current_path
        SIDES.each { |side| generate_command(side) }
      end

      private

      def prefix
        @label.empty? ? "" : "#{@label}."
      end

      def side_path(side)
        value = @data.dig(side, "path")
        unless value.is_a?(String) && !value.empty?
          raise Error, "#{prefix}#{side}.path is required in #{@file}"
        end

        File.expand_path(value, @root)
      end
    end

    DEFAULT_FILENAME = "twinshot.yml"
    DEFAULT_MAX_DIFF_RATIO = 0.002
    REPORT_DIRNAME = "twinshot-report"
    HUMAN_REPORT = "report_for_human.html"
    AGENT_REPORT = "report_for_agent.md"
    DEFAULT_GROUP = "default"
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

    # All groups in run order: the unnamed default first, then named ones
    # in declaration order.
    def groups
      @groups ||= [default_group, *named_groups]
    end

    def group(name)
      groups.find { |g| g.name == name } ||
        raise(Error, "unknown group: #{name.inspect} (expected #{groups.map(&:name).join(', ')})")
    end

    # Default-group delegates (compatibility with the pre-groups API).
    def oracle_path
      default_group.oracle_path
    end

    def current_path
      default_group.current_path
    end

    def generate_command(side)
      default_group.generate_command(side)
    end

    def max_diff_ratio
      value = @data.dig("png", "max_diff_ratio") || DEFAULT_MAX_DIFF_RATIO
      Float(value)
    rescue ArgumentError, TypeError
      raise Error, "png.max_diff_ratio must be a number, got: #{value.inspect}"
    end

    def report_root
      File.join(@root, REPORT_DIRNAME)
    end

    # Each group reports into twinshot-report/<name>/.
    def report_dir(group = nil)
      File.join(report_root, group ? group.name : DEFAULT_GROUP)
    end

    private

    def default_group
      Group.new(DEFAULT_GROUP,
                { "oracle" => @data["oracle"], "current" => @data["current"] },
                @root, File.basename(@path), "")
    end

    def named_groups
      groups_data = @data["groups"] || {}
      unless groups_data.is_a?(Hash)
        raise Error, "groups must be a mapping of name to oracle/current sides"
      end

      groups_data.map do |name, data|
        unless name.is_a?(String) && !name.empty?
          raise Error, "group names must be non-empty strings, got: #{name.inspect}"
        end
        if name == DEFAULT_GROUP
          raise Error, "group name #{DEFAULT_GROUP.inspect} is reserved for the unnamed top-level group"
        end

        Group.new(name, data, @root, File.basename(@path), "groups.#{name}")
      end
    end

    def validate!
      raise Error, "config root must be a mapping" unless @data.is_a?(Hash)

      @data.each do |key, value|
        raise Error, "#{key} must be a mapping" if key != "png" && !value.is_a?(Hash)
      end
      groups.each(&:validate!)
      max_diff_ratio
    end
  end
end
