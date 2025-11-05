# frozen_string_literal: true

require 'rubocop/sorted_methods_by_call/compare'

RSpec.describe RuboCop::SortedMethodsByCall::Compare do
  describe '.subsequence?' do
    it 'returns true for an ordered subsequence' do
      arr = %i[abc foo bar a hello]
      expect(described_class.subsequence?(arr, %i[foo bar hello])).to be true
    end

    it 'returns false for an out-of-order subsequence' do
      arr = %i[abc foo bar a hello]
      expect(described_class.subsequence?(arr, %i[bar foo])).to be false
    end

    it 'returns true for empty subsequence' do
      expect(described_class.subsequence?(%i[x y], [])).to be true
    end
  end

  describe '.hashes_ordered_equal?' do
    it 'returns true when calls are a subsequence of defs per scope' do
      defs  = { main: %i[abc foo bar a hello] }
      calls = { main: %i[foo bar hello] }
      expect(described_class.hashes_ordered_equal?(defs, calls)).to be true
    end

    it 'returns false when order is violated' do
      defs  = { main: %i[abc foo bar a hello] }
      calls = { main: %i[bar foo] }
      expect(described_class.hashes_ordered_equal?(defs, calls)).to be false
    end

    it 'returns false when calls reference unknown methods' do
      defs  = { main: %i[foo bar] }
      calls = { main: %i[foo baz] }
      expect(described_class.hashes_ordered_equal?(defs, calls)).to be false
    end
  end
end
