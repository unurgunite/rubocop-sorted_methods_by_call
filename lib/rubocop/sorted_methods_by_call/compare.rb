# frozen_string_literal: true

module RuboCop
  module SortedMethodsByCall
    module Compare
      class << self
        # Returns true if `sub` is a subsequence of `arr` (order preserved).
        def subsequence?(arr, sub)
          return true if sub.nil? || sub.empty?

          i = 0
          sub.each do |el|
            found = false
            while i < arr.length
              if arr[i] == el
                found = true
                i += 1
                break
              end
              i += 1
            end
            return false unless found
          end
          true
        end

        # For each scope: calls must exist in defs and be a subsequence.
        def hashes_ordered_equal?(a, b)
          return false unless a.is_a?(Hash) && b.is_a?(Hash)

          (a.keys | b.keys).all? do |k|
            defs = Array(a[k])
            calls = Array(b[k])
            (calls - defs).empty? && subsequence?(defs, calls)
          end
        end
      end
    end
  end
end
