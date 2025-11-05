# frozen_string_literal: true

module RuboCop
  module SortedMethodsByCall
    module Util # :nodoc:
      # +RuboCop::SortedMethodsByCall::Util.deep_merge(hash, other)+ -> Hash
      #
      # Merges two hashes without overwriting values that share the same key.
      # When a key exists in both hashes, values are accumulated into an array
      # ("buckets"). Scalars are wrapped to arrays automatically.
      #
      # - Non-destructive: returns a new Hash; does not mutate +hash+.
      # - If +other+ is not a Hash, the original +hash+ is returned as-is.
      #
      # @example Accumulate values into buckets
      #   base  = { main: :abc, class_T: :hi }
      #   other = { class_T: :h1 }
      #   RuboCop::SortedMethodsByCall::Util.deep_merge(base, other)
      #   #=> { main: [:abc], class_T: [:hi, :h1] }
      #
      # @param [Hash] hash  The base hash to merge from.
      # @param [Hash] other The hash to merge into +hash+.
      # @return [Hash] A new hash with accumulated values per key.
      # @see Hash#merge
      def self.deep_merge(h, other)
        return h unless other.is_a?(Hash)

        h.merge(other) { |_, a, b| Array(a) + Array(b) }
      end
    end
  end
end
