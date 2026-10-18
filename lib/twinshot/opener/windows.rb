# frozen_string_literal: true

module Twinshot
  # Adapter registry entry — see lib/twinshot/opener.rb.
  module Opener
    # Windows: `start` is a cmd.exe builtin, so it needs the cmd wrapper.
    # The empty-string arg is the window title — without it `start` would
    # eat a quoted path as the title and open a console instead.
    module Windows
      module_function

      def open(path)
        Opener.launch("cmd", "/c", "start", "", path) ||
          raise(Error, "`start #{path}` failed")
      end
    end

    Opener.register "windows", Windows
  end
end
