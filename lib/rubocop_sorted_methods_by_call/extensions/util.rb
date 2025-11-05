# frozen_string_literal: true

module RubocopSortedMethodsByCall
  module Util # :nodoc:
    # +RubocopSortedMethodsByCall::Util.deep_merge(other)+                           -> Hash
    #
    # This method merges two hashes without overriding identical keys during
    # name pollutions.
    #
    # @example
    #   a = {:main=>[:abc], :class_T=>[:hi]}
    #   b = {:class_T=>:h1}
    #   a.deep_merge(b) #=>  {:main=>[:abc], :class_T=>[:hi, :h1]} # values are stored in 'buckets'
    # @param [Hash] other Some hash.
    # @return [NilClass] if +other+ is not a Hash object.
    # @return [Hash]
    def self.deep_merge(h, other)
      return h unless other.is_a?(Hash)

      h.merge(other) { |_, a, b| Array(a) + Array(b) }
    end
  end
end
