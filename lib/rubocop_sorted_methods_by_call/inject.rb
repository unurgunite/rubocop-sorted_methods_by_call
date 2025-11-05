# frozen_string_literal: true

module RubocopSortedMethodsByCall
  module Inject
    def self.defaults!
      return unless defined?(::RuboCop::ConfigLoader)

      path = File.expand_path("../../config/default.yml", __dir__)
      hash =
        if defined?(::RuboCop::YAML) && ::RuboCop::YAML.respond_to?(:safe_load_file)
          ::RuboCop::YAML.safe_load_file(path)
        else
          require "yaml"
          YAML.safe_load_file(path, permitted_classes: [Regexp], aliases: true) || {}
        end

      config = ::RuboCop::Config.new(hash, path)
      config.make_excludes_absolute if config.respond_to?(:make_excludes_absolute)

      ::RuboCop::ConfigLoader.default_configuration =
        ::RuboCop::ConfigLoader.merge_with_default(config, path)
    end
  end
end
