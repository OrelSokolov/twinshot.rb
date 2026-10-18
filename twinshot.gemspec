# frozen_string_literal: true

require_relative "lib/twinshot/version"

Gem::Specification.new do |spec|
  spec.name = "twinshot"
  spec.version = Twinshot::VERSION
  spec.authors = ["Oleg Orlov"]
  spec.email = ["orelcokolov@gmail.com"]

  spec.summary = "1:1 artifact parity: compare two directory trees (oracle vs current) file by file via format adapters"
  spec.description = "Compares a verified oracle tree against a current tree: structure check first, then per-file similarity through adapters (html by structure, txt by lines, png by pixels, binaries by bytes). Any unknown file is a failure."
  spec.homepage = "https://github.com/OrelSokolov/twinshot.rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  spec.add_dependency "chunky_png", "~> 1.4"
  spec.add_dependency "diff-lcs", "~> 2.0"
  spec.add_dependency "nokogiri", "~> 1.16"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
