# frozen_string_literal: true

require 'rubocop/rspec/support'
require 'rubocop-sorted_methods_by_call'

RSpec.describe RuboCop::Cop::SortedMethodsByCall::Waterfall, :config do
  let(:config) do
    RuboCop::Config.new(
      'SortedMethodsByCall/Waterfall' => { 'Enabled' => true }
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

  context 'with complex call graphs' do
    it 'handles methods called from multiple places' do
      expect_offense(<<~RUBY)
        class Service
          def call
            foo
            bar
          end

          private

          def foo
          ^^^^^^^ Define #foo after its caller #method123 (waterfall order).
            123
          end

          def bar
            method123
          end

          def method123
            foo
          end
        end
      RUBY

      expect_correction(<<~RUBY)
        class Service
          def call
            foo
            bar
          end

          private

          def bar
            method123
          end

          def method123
            foo
          end

          def foo
            123
          end
        end
      RUBY
    end
  end

  context 'with sibling ordering (orchestration methods)' do
    it 'detects when methods called in sequence are defined out of order' do
      expect_offense(<<~RUBY)
        class SomeClass
          def build
            klass = Class.new
            bar(klass)
            foo(klass)
            klass
          end

          private

          def foo(klass)
          ^^^^^^^^^^^^^^ Define #foo after #bar to match the order they are called together
            # implementation
          end

          def bar(klass)
            # implementation
          end
        end
      RUBY

      expect_correction(<<~RUBY)
        class SomeClass
          def build
            klass = Class.new
            bar(klass)
            foo(klass)
            klass
          end

          private

          def bar(klass)
            # implementation
          end

          def foo(klass)
            # implementation
          end
        end
      RUBY
    end

    it 'accepts methods defined in the same order they are called together' do
      expect_no_offenses(<<~RUBY)
        class Generator
          def build
            klass = Class.new
            define_instance_methods(klass)
            define_class_methods(klass)
            klass
          end

          private

          def define_instance_methods(klass)
            # implementation
          end

          def define_class_methods(klass)
            # implementation
          end
        end
      RUBY
    end

    it 'does not enforce sibling ordering when methods also have direct call relationships' do
      expect_no_offenses(<<~RUBY)
        class Service
          def orchestrate
            prepare_data
            process_data
          end

          def process_data
            prepare_data  # direct call relationship exists
          end

          def prepare_data
            # implementation
          end
        end
      RUBY
    end

    it 'handles multiple sibling relationships in complex orchestration' do
      expect_offense(<<~RUBY)
        class Pipeline
          def run
            step_one
            step_two
            step_three
          end

          def step_three
          ^^^^^^^^^^^^^^ Define #step_three after #step_two to match the order they are called together
            # third
          end

          def step_one
            # first
          end

          def step_two
            # second
          end
        end
      RUBY

      expect_correction(<<~RUBY)
        class Pipeline
          def run
            step_one
            step_two
            step_three
          end

          def step_one
            # first
          end

          def step_two
            # second
          end

          def step_three
            # third
          end
        end
      RUBY
    end
  end

  context 'when non-contiguous sections' do
    it 'does not autocorrect across a nested class' do
      source = <<~RUBY
        class Demo
          def b
            1
          end

          class Inner
            def something; end
          end

          def a
            b
          end
        end
      RUBY

      expect_offense(<<~RUBY, source: source)
        class Demo
          def b
          ^^^^^ Define #b after its caller #a (waterfall order).
            1
          end

          class Inner
            def something; end
          end

          def a
            b
          end
        end
      RUBY

      expect_no_corrections
    end

    it 'autocorrects within a contiguous section and preserves a nested class below' do
      expect_offense(<<~RUBY)
        class Demo
          def d
          ^^^^^ Define #d after its caller #c (waterfall order).
            1
          end

          def c
            d
          end

          class Inner
            def hmm; end
          end
        end
      RUBY

      expect_correction(<<~RUBY)
        class Demo
          def c
            d
          end

          def d
            1
          end

          class Inner
            def hmm; end
          end
        end
      RUBY
    end

    it 'does not autocorrect across a non-visibility send' do
      source = <<~RUBY
        class Demo
          def b
            1
          end

          before_action :x

          def a
            b
          end
        end
      RUBY

      expect_offense(<<~RUBY, source: source)
        class Demo
          def b
          ^^^^^ Define #b after its caller #a (waterfall order).
            1
          end

          before_action :x

          def a
            b
          end
        end
      RUBY

      expect_no_corrections
    end
  end
end
