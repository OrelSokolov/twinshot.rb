# frozen_string_literal: true

module Twinshot
  # Adapter registry entry — see lib/twinshot/opener.rb.
  module Opener
    # Linux and the BSDs: `xdg-open`. Also the fallback family for any
    # host_os the case above does not recognize.
    module Linux
      module_function

      def open(path)
        Opener.launch("xdg-open", path) ||
          raise(Error, "`xdg-open #{path}` failed (is xdg-open installed?)")
      end
    end

    Opener.register "linux", Linux
  end
end
