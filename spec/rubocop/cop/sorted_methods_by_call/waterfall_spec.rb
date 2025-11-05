# frozen_string_literal: true

require 'rubocop/rspec/support'
require 'rubocop-sorted_methods_by_call'

RSpec.describe RuboCop::Cop::SortedMethodsByCall::Waterfall, :config do
  let(:config) do
    RuboCop::Config.new(
      'SortedMethodsByCall/Waterfall' => { 'Enabled' => true, 'SafeAutoCorrect' => false }
    )
  end

  it 'accepts waterfall order' do
    expect_no_offenses(<<~RUBY)
      def foo
        bar
      end

      def bar
        123
      end
    RUBY
  end

  it 'registers offense when callee is defined before caller' do
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

  context 'when recursion is used' do
    it 'ignores recursive self-calls' do
      expect_no_offenses(<<~RUBY)
        def factorial(n)
          return 1 if n <= 1
          factorial(n - 1)
        end
      RUBY
    end
  end

  context 'with nested class scopes' do
    it 'accepts well-ordered nested classes' do
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

  context 'when methods are out of order in a class' do
    it 'registers an offense' do
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

  context 'with modules' do
    it 'detects offenses within module scope' do
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

  context 'with singleton class (class << self)' do
    it 'handles singleton method definitions' do
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

  it 'reorders methods and preserves leading doc comments in a simple section' do
    expect_offense(<<~RUBY)
      class S
        # Doc for well
        # does something
        def well
        ^^^^^^^^ Define #well after its caller #do_smth (waterfall order).
          1
        end

        # Doc for do_smth
        def do_smth
          well
        end
      end
    RUBY

    expect_correction(<<~RUBY)
      class S
        # Doc for do_smth
        def do_smth
          well
        end

        # Doc for well
        # does something
        def well
          1
        end
      end
    RUBY
  end

  it 'does not cross visibility sections (no autocorrect across private/public)' do
    source = <<~RUBY
      class T
        private

        def callee
          1
        end

        public

        def caller
          callee
        end
      end
    RUBY

    expect_offense(<<~RUBY, source: source)
      class T
        private

        def callee
        ^^^^^^^^^^ Define #callee after its caller #caller (waterfall order).
          1
        end

        public

        def caller
          callee
        end
      end
    RUBY

    # No changes expected because caller/callee are in different sections
    expect_no_corrections
  end

  it "reorders within a private section and keeps the single visibility line" do
    expect_offense(<<~RUBY)
      class S
        private

        def b
        ^^^^^ Define #b after its caller #a (waterfall order).
          1
        end

        def a
          b
        end
      end
    RUBY

    expect_correction(<<~RUBY)
      class S
        private

        def a
          b
        end

        def b
          1
        end
      end
    RUBY
  end

  it "reorders within a protected section and keeps the single visibility line" do
    expect_offense(<<~RUBY)
      class S
        protected

        def b
        ^^^^^ Define #b after its caller #a (waterfall order).
          1
        end

        def a
          b
        end
      end
    RUBY

    expect_correction(<<~RUBY)
      class S
        protected

        def a
          b
        end

        def b
          1
        end
      end
    RUBY
  end
end
