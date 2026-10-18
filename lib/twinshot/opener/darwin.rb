# frozen_string_literal: true

module Twinshot
  # Adapter registry entry — see lib/twinshot/opener.rb.
  module Opener
    # macOS: the original `open`.
    module Darwin
      module_function

      def open(path)
        Opener.launch("open", path) ||
          raise(Error, "`open #{path}` failed")
      end
    end

    Opener.register "darwin", Darwin
  end
end
