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
      # +RuboCop::SortedMethodsByCall::Plugin#about+ -> LintRoller::About
      #
      # Declares plugin metadata (name, version, homepage, description).
      #
      # @return [LintRoller::About] Metadata describing this plugin.
      def about
        LintRoller::About.new(
          name: 'rubocop-sorted_methods_by_call',
          version: VERSION,
          homepage: 'https://github.com/unurgunite/rubocop-sorted_methods_by_call',
          description: 'Enforces waterfall ordering: define methods after the methods that call them.'
        )
      end

      # +RuboCop::SortedMethodsByCall::Plugin#supported?+ -> Boolean
      #
      # Indicates that this plugin supports RuboCop as the lint engine.
      #
      # @param [Object] context LintRoller context (engine, versions, etc.).
      # @return [Boolean] true for RuboCop engine; false otherwise.
      def supported?(context)
        context.engine == :rubocop
      end

      # +RuboCop::SortedMethodsByCall::Plugin#rules+ -> LintRoller::Rules
      #
      # Returns the plugin rules for RuboCop. This points RuboCop to the default
      # configuration file shipped with the gem (config/default.yml).
      #
      # @param [Object] _context LintRoller context (unused).
      # @return [LintRoller::Rules] Rule declaration for RuboCop to load.
      #
      # @see config/default.yml
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
