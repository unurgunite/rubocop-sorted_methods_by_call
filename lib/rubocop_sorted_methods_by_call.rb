# frozen_string_literal: true

require_relative "rubocop_sorted_methods_by_call/version"
require_relative "rubocop_sorted_methods_by_call/inject"

# Inject defaults only if RuboCop is present (it is in normal usage and in specs)
RubocopSortedMethodsByCall::Inject.defaults!

# Load cops (they require their own RuboCop bits)
require_relative "rubocop/cop/sorted_methods_by_call/waterfall"
