# frozen_string_literal: true

require_relative "lib/rubocop_sorted_methods_by_call/version"

Gem::Specification.new do |spec|
  spec.name = "rubocop_sorted_methods_by_call"
  spec.version = RubocopSortedMethodsByCall::VERSION
  spec.authors = ["unurgunite"]
  spec.email = ["senpaiguru1488@gmail.com"]

  spec.summary = "RuboCop extension for method sorting in AST by stack trace."
  spec.homepage = "https://github.com/unurgunite/rubocop_sorted_methods_by_call"
  spec.required_ruby_version = ">= 2.5.0"

  spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/unurgunite/rubocop_sorted_methods_by_call"
  spec.metadata["changelog_uri"] = "https://github.com/unurgunite/rubocop_sorted_methods_by_call/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/rubocop_sorted_methods_by_call/extconf.rb"]

  spec.add_dependency "racc", ">= 1.6"
  spec.add_dependency "rubocop", ">= 1.56", "< 2.0"

  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "rake-compiler"
  spec.add_development_dependency "rspec", ">= 3.0"
  spec.add_development_dependency "yard"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
