# frozen_string_literal: true

require 'lint_roller'
require_relative 'version'

module RuboCop
  module SortedMethodsByCall
    # +RuboCop::SortedMethodsByCall::Plugin+ integrates this extension with RuboCop's
    # plugin system via lint_roller. It declares metadata and tells RuboCop where
    # to find the plugin's default configuration.
    #
    # The plugin is discovered by RuboCop when you configure:
    #   plugins:
    #     - rubocop-sorted_methods_by_call
    #
    # It will automatically apply rules (config/default.yml) and make the cops
    # available to the engine.
    class Plugin < LintRoller::Plugin
      # Return plugin metadata for lint_roller discovery.
      #
      # @return [About]
      def about
        LintRoller::About.new(
          name: 'rubocop-sorted_methods_by_call',
          version: VERSION,
          homepage: 'https://github.com/unurgunite/rubocop-sorted_methods_by_call',
          description: 'Enforces waterfall ordering: define methods after the methods that call them.'
        )
      end

      # Check if the plugin is supported for the given lint_roller context.
      #
      # @param [Object] context The lint_roller context to check.
      # @return [Object]
      def supported?(context)
        context.engine == :rubocop
      end

      # Return the RuboCop rules configuration path.
      #
      # @param [Object] _context The lint_roller context (unused).
      # @return [Rules]
      def rules(_context)
        LintRoller::Rules.new(
          type: :path,
          config_format: :rubocop,
          value: Pathname.new(__dir__ || '').realpath.join('../../../config/default.yml')
        )
      end
    end
  end
end
