# frozen_string_literal: true

require_relative 'lib/rubocop/sorted_methods_by_call/version'

Gem::Specification.new do |spec|
  spec.name = 'rubocop-sorted_methods_by_call'
  spec.version = RuboCop::SortedMethodsByCall::VERSION
  spec.authors = ['unurgunite']
  spec.email = ['senpaiguru1488@gmail.com']

  spec.summary = 'RuboCop extension for method sorting in AST by stack trace.'
  spec.homepage = 'https://github.com/unurgunite/rubocop-sorted_methods_by_call'
  spec.required_ruby_version = '>= 2.6.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/unurgunite/rubocop-sorted_methods_by_call'
  spec.metadata['changelog_uri'] = 'https://github.com/unurgunite/rubocop-sorted_methods_by_call/CHANGELOG.md'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'lint_roller'
  spec.add_dependency 'rubocop', '>= 1.72.0'

  spec.metadata['default_lint_roller_plugin'] = 'RuboCop::SortedMethodsByCall::Plugin'

  spec.add_development_dependency 'fasterer'
  spec.add_development_dependency 'rake', '>= 13.0'
  spec.add_development_dependency 'rspec', '>= 3.0'
  spec.add_development_dependency 'rubocop-performance'
  spec.add_development_dependency 'rubocop-rake'
  spec.add_development_dependency 'rubocop-rspec'
  spec.add_development_dependency 'yard'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
