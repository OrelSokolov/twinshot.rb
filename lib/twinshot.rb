# frozen_string_literal: true

require_relative "twinshot/version"
require_relative "twinshot/config"
require_relative "twinshot/tree"
require_relative "twinshot/adapters"
require_relative "twinshot/compare"
require_relative "twinshot/progress"
require_relative "twinshot/report"
require_relative "twinshot/cli"

# Twinshot: 1:1 artifact parity between a verified oracle tree and a current
# tree. Structure must match; every file goes through a format adapter
# (png by pixels, html by structure, txt by lines, binaries by bytes).
# Any unknown file is a failure.
module Twinshot
end
