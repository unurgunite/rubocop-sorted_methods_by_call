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
  context "when recursion is used" do
    it "ignores recursive self-calls" do
      expect_no_offenses(<<~RUBY)
        def factorial(n)
          return 1 if n <= 1
          factorial(n - 1)
        end
      RUBY
    end
  end

  context "with nested class scopes" do
    it "accepts well-ordered nested classes" do
      expect_no_offenses(<<~RUBY)
        class Outer
          def alpha; beta; end
          def beta;  1; end

          class Inner
            def inside; helper; end
            def helper; 2; end
          end
        end
      RUBY
    end
  end

  context "when methods are out of order in a class" do
    it "registers an offense" do
      expect_offense(<<~RUBY)
        class Example
          def bar; helper; end
          ^^^^^^^^^^^^^^^^^^^^ Define #bar after its caller #foo (waterfall order).
          def helper; 1; end
          def foo
            bar
          end
        end
      RUBY
    end
  end

  context "with modules" do
    it "detects offenses within module scope" do
      expect_offense(<<~RUBY)
        module Util
          def bar; 1; end
          ^^^^^^^^^^^^^^^ Define #bar after its caller #foo (waterfall order).
          def foo
            bar
          end
        end
      RUBY
    end
  end

  context "with singleton class (class << self)" do
    it "handles singleton method definitions" do
      expect_no_offenses(<<~RUBY)
        class X
          class << self
            def first; second; end
            def second; 1; end
          end
        end
      RUBY
    end
  end
end
