# frozen_string_literal: true

module RuboCop
  module SortedMethodsByCall
    # +RuboCop::SortedMethodsByCall::Compare+ provides helpers to compare
    # definition orders and call orders using "ordered subsequence" semantics.
    # It’s used by the cop to check that called methods appear in the same
    # relative order as they are defined (not necessarily contiguously).
    module Compare
      class << self
        # +RuboCop::SortedMethodsByCall::Compare.hashes_ordered_equal?(actual, expected)+ -> Bool
        #
        # For each scope key, checks that every call in +expected[k]+ exists in +actual[k]+ and
        # appears in the same relative order (i.e., +expected[k]+ is a subsequence of +actual[k]+).
        # Returns false if a call is unknown (not present in +actual[k]+) or out of order.
        #
        # @example
        #   defs  = { main: %i[abc foo bar a hello] }
        #   calls = { main: %i[foo bar hello] }
        #   RuboCop::SortedMethodsByCall::Compare.hashes_ordered_equal?(defs, calls) #=> true
        #
        #   calls2 = { main: %i[bar foo] }
        #   RuboCop::SortedMethodsByCall::Compare.hashes_ordered_equal?(defs, calls2) #=> false
        #
        # @param [Hash{Object=>Array<Symbol>}] actual   Actual definitions per scope.
        # @param [Hash{Object=>Array<Symbol>}] expected Expected calls per scope.
        # @return [Bool] true if for every scope +k+, +expected[k]+ is a subsequence of +actual[k]+
        #   and contains no unknown methods.
        def hashes_ordered_equal?(actual, expected)
          return false unless actual.is_a?(Hash) && expected.is_a?(Hash)

          (actual.keys | expected.keys).all? do |k|
            defs = Array(actual[k])
            calls = Array(expected[k])
            (calls - defs).empty? && subsequence?(defs, calls)
          end
        end

        def subsequence?(arr, sub)
          return true if sub.nil? || sub.empty?

          i = 0
          sub.all? do |el|
            i += 1 while i < arr.length && arr[i] != el
            (i < arr.length).tap { i += 1 }
          end
        end
      end
    end
  end
end
