# frozen_string_literal: true

module RubocopSortedMethodsByCall
  module Compare
    class << self
      # Returns true if `sub` is a subsequence of `arr` (order preserved, not necessarily contiguous).
      # Empty subsequence is always true.
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

      # Compare two scope->methods hashes using ordered subsequence semantics.
      # - a: actual definition order per scope
      # - b: expected call order per scope
      #
      # For each scope key, every called method must:
      #   1) exist in the definitions of that scope
      #   2) appear in the same relative order as defined (not necessarily contiguous)
      def hashes_ordered_equal?(a, b)
        return false unless a.is_a?(Hash) && b.is_a?(Hash)

        keys = (a.keys | b.keys)
        keys.all? do |k|
          defs  = Array(a[k])
          calls = Array(b[k])

          # All calls must be defined in this scope
          next false unless (calls - defs).empty?

          # Calls must be a subsequence of defs (order preserved)
          subsequence?(defs, calls)
        end
      end
    end
  end
end
