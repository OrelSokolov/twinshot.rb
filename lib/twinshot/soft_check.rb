# frozen_string_literal: true

module Twinshot
  # soft_check matching, shared by Config (parent process) and
  # compare_worker.rb (exec'd workers): an entry is either an exact
  # tree-relative path or a glob pattern. Matched with File.fnmatch without
  # FNM_PATHNAME, so "*" crosses "/" — "code/capybara-tests/*" covers the
  # whole subtree, nested files included. FNM_DOTMATCH keeps dotfiles
  # (.gitignore) matchable by "*".
  module SoftCheck
    FLAGS = File::FNM_DOTMATCH

    module_function

    def match?(paths, rel)
      paths.any? { |path| File.fnmatch(path, rel, FLAGS) }
    end
  end
end
