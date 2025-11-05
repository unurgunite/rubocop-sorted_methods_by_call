# frozen_string_literal: true

require "rubocop/rspec/support"
require "rubocop_sorted_methods_by_call"

RSpec.describe RuboCop::Cop::SortedMethodsByCall::Waterfall, :config do
  let(:config) do
    RuboCop::Config.new(
      "SortedMethodsByCall/Waterfall" => { "Enabled" => true, "SafeAutoCorrect" => false }
    )
  end

  it "accepts waterfall order" do
    expect_no_offenses(<<~RUBY)
      def foo
        bar
      end

      def bar
        123
      end
    RUBY
  end

  it "registers offense when callee is defined before caller" do
    expect_offense(<<~RUBY)
      def bar
      ^^^^^^^ Define #bar after its caller #foo (waterfall order).
        123
      end

      def foo
        bar
      end
    RUBY
  end
end
