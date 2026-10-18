# frozen_string_literal: true

require "digest"

module Twinshot
  # Adapter implementations (the contract lives in adapters.rb).
  module Adapters
    # Byte-for-byte comparison via SHA-256.
    module Binary
      module_function

      def call(_rel, oracle_file, current_file, _ctx)
        same = Digest::SHA256.file(oracle_file).hexdigest == Digest::SHA256.file(current_file).hexdigest
        { "kind" => "binary", "status" => same ? "pass" : "fail",
          "detail" => same ? "bytes equal" : "bytes differ" }
      end
    end

    register(Binary, "bin", "dat")
  end
end
