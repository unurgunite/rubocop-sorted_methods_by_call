# frozen_string_literal: true

module RuboCop
  module SortedMethodsByCall
    # +RuboCop::SortedMethodsByCall::Compare+ provides helpers to compare
    # definition orders and call orders using "ordered subsequence" semantics.
    # It’s used by the cop to check that called methods appear in the same
    # relative order as they are defined (not necessarily contiguously).
    module Compare
      class << self
        # Check that each scope's call list is an ordered subsequence of its definition list.
        #
        # @param [Hash<Object, Array<Symbol>>] actual Per-scope definition method names.
        # @param [Hash<Object, Array<Symbol>>] expected Per-scope called method names.
        # @return [Boolean]
        def hashes_ordered_equal?(actual, expected)
          return false unless actual.is_a?(Hash) && expected.is_a?(Hash)

          (actual.keys | expected.keys).all? do |k|
            defs = Array(actual[k])
            calls = Array(expected[k])
            (calls - defs).empty? && subsequence?(defs, calls)
          end
        end

        # Check if +sub+ appears as an ordered (not necessarily contiguous) subsequence of +arr+.
        #
        # @param [Array<Symbol>] arr The full sequence to search within.
        # @param [Array<Symbol>] sub The subsequence to search for.
        # @return [Boolean]
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
