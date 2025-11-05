# ./lib/rubocop/sorted_methods_by_call/plugin.rb
# frozen_string_literal: true

require 'lint_roller'
require_relative 'version'

module RuboCop
  module SortedMethodsByCall
    # A plugin that integrates RuboCop SortedMethodsByCall with RuboCop's plugin system.
    class Plugin < LintRoller::Plugin
      def about
        LintRoller::About.new(
          name: 'rubocop-sorted_methods_by_call',
          version: VERSION,
          homepage: 'https://github.com/unurgunite/rubocop-sorted_methods_by_call',
          description: 'Enforces waterfall ordering: define methods after the methods that call them.'
        )
      end

      def supported?(context)
        context.engine == :rubocop
      end

      def rules(_context)
        LintRoller::Rules.new(
          type: :path,
          config_format: :rubocop,
          value: Pathname.new(__dir__).join('../../../config/default.yml')
        )
      end
    end
  end
end
