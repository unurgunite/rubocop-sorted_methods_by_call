# frozen_string_literal: true

require 'rubocop/rspec/support'
require 'rubocop-sorted_methods_by_call'

RSpec.describe RuboCop::Cop::SortedMethodsByCall::Waterfall, :config do
  let(:config) do
    RuboCop::Config.new(
      'SortedMethodsByCall/Waterfall' => { 'Enabled' => true }
    )
  end

  context 'when callers appear before callees' do
    subject(:source) { <<~RUBY }
      def foo
        bar
      end

      def bar
        123
      end
    RUBY

    it 'accepts waterfall order' do
      expect_no_offenses(source)
    end
  end

  context 'when callee is defined before caller' do
    subject(:source) { <<~RUBY }
      def bar
      ^^^^^^^ Define #bar after its caller #foo (waterfall order).
        123
      end

      def foo
        bar
      end
    RUBY

    it 'registers offense' do
      expect_offense(source)
    end
  end

  context 'with recursion' do
    subject(:source) { <<~RUBY }
      def factorial(n)
        return 1 if n <= 1
        factorial(n - 1)
      end
    RUBY

    it 'ignores recursive self-calls' do
      expect_no_offenses(source)
    end
  end

  context 'with nested class scopes' do
    subject(:source) { <<~RUBY }
      class Outer
        def alpha; beta; end
        def beta;  1; end

        class Inner
          def inside; helper; end
          def helper; 2; end
        end
      end
    RUBY

    it 'accepts well-ordered nested classes' do
      expect_no_offenses(source)
    end
  end

  context 'with methods out of order in a class' do
    subject(:source) { <<~RUBY }
      class Example
        def bar; helper; end
        ^^^^^^^^^^^^^^^^^^^^ Define #bar after its caller #foo (waterfall order).
        def helper; 1; end
        def foo
          bar
        end
      end
    RUBY

    it 'registers an offense' do
      expect_offense(source)
    end
  end

  context 'with modules' do
    subject(:source) { <<~RUBY }
      module Util
        def bar; 1; end
        ^^^^^^^^^^^^^^^ Define #bar after its caller #foo (waterfall order).
        def foo
          bar
        end
      end
    RUBY

    it 'detects offenses within module scope' do
      expect_offense(source)
    end
  end

  context 'with singleton class (class << self)' do
    subject(:source) { <<~RUBY }
      class X
        class << self
          def first; second; end
          def second; 1; end
        end
      end
    RUBY

    it 'handles singleton method definitions' do
      expect_no_offenses(source)
    end
  end

  context 'with autocorrect across sections of the same visibility' do
    subject(:source) { <<~RUBY }
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

    let(:corrected_source) { <<~RUBY }
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

    it 'reorders methods and preserves leading doc comments' do
      expect_offense(source)
      expect_correction(corrected_source)
    end
  end

  context 'with cross-visibility sections' do
    subject(:source) { <<~RUBY }
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

    let(:offense_source) { <<~RUBY }
      class T
        private

        def callee
        ^^^^^^^^^^ Define #callee after its caller #caller (waterfall order). (Autocorrect not supported across visibility boundaries: public vs private.)
          1
        end

        public

        def caller
          callee
        end
      end
    RUBY

    it 'does not cross visibility sections' do
      expect_offense(offense_source, source: source)
      expect_no_corrections
    end
  end

  context 'with a private section' do
    subject(:source) { <<~RUBY }
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

    let(:corrected_source) { <<~RUBY }
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

    it 'reorders and keeps the single visibility line' do
      expect_offense(source)
      expect_correction(corrected_source)
    end
  end

  context 'with helper_method declarations inside a visibility block' do
    subject(:source) { <<~RUBY }
      class TestController
        private

        helper_method :some_helper_used_in_a_view

        def some_helper_used_in_a_view
          'assume I need this somewhere else in a view'
        end

        def inner_method
        ^^^^^^^^^^^^^^^^ Define #inner_method after its caller #outer_method (waterfall order).
          'x'
        end

        def outer_method
          inner_method
        end
      end
    RUBY

    let(:corrected_source) { <<~RUBY }
      class TestController
        private

        helper_method :some_helper_used_in_a_view

        def some_helper_used_in_a_view
          'assume I need this somewhere else in a view'
        end

        def outer_method
          inner_method
        end

        def inner_method
          'x'
        end
      end
    RUBY

    it 'does not delete helper_method declarations' do
      expect_offense(source)
      expect_correction(corrected_source)
    end
  end

  context 'with a protected section' do
    subject(:source) { <<~RUBY }
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

    let(:corrected_source) { <<~RUBY }
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

    it 'reorders and keeps the single visibility line' do
      expect_offense(source)
      expect_correction(corrected_source)
    end
  end

  context 'with complex call graphs' do
    subject(:source) { <<~RUBY }
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

    let(:corrected_source) { <<~RUBY }
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

    it 'handles methods called from multiple places' do
      expect_offense(source)
      expect_correction(corrected_source)
    end
  end

  context 'with sibling ordering (orchestration methods)' do
    context 'when methods called in sequence are defined out of order' do
      let(:sibling_order_source) { <<~RUBY }
        class SomeClass
          def build
            klass = Class.new
            bar(klass)
            foo(klass)
            klass
          end

          private

          def foo(klass)
          ^^^^^^^^^^^^^^ Define #foo after #bar to match the order they are called together.
            # implementation
          end

          def bar(klass)
            # implementation
          end
        end
      RUBY

      let(:sibling_order_corrected) { <<~RUBY }
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

      it 'detects when methods called in sequence are defined out of order' do
        expect_offense(sibling_order_source)
        expect_correction(sibling_order_corrected)
      end
    end

    context 'when methods are defined in the same order they are called together' do
      let(:sibling_accept_source) { <<~RUBY }
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

      it 'accepts methods defined in the same order they are called together' do
        expect_no_offenses(sibling_accept_source)
      end
    end

    context 'when methods also have direct call relationships' do
      let(:sibling_with_direct_source) { <<~RUBY }
        class Service
          def orchestrate
            prepare_data
            process_data
          end

          def process_data
            prepare_data
          end

          def prepare_data
            # implementation
          end
        end
      RUBY

      it 'does not enforce sibling ordering' do
        expect_no_offenses(sibling_with_direct_source)
      end
    end

    context 'with multiple sibling relationships in complex orchestration' do
      let(:complex_sibling_source) { <<~RUBY }
        class Pipeline
          def run
            step_one
            step_two
            step_three
          end

          def step_three
          ^^^^^^^^^^^^^^ Define #step_three after #step_two to match the order they are called together.
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

      let(:complex_sibling_corrected) { <<~RUBY }
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

      it 'handles multiple sibling relationships in complex orchestration' do
        expect_offense(complex_sibling_source)
        expect_correction(complex_sibling_corrected)
      end
    end

    context 'when sibling ordering creates a cycle with direct call dependencies' do
      let(:cycle_enabled_config) do
        RuboCop::Config.new(
          'SortedMethodsByCall/Waterfall' => { 'Enabled' => true, 'AllowedRecursion' => false }
        )
      end
      let(:config) { cycle_enabled_config }

      let(:source) { <<~RUBY }
        class SiblingCycleExample
          def call
            a
            b
          end

          private

          # NOTE: Direct dependencies:
          # b -> c -> a
          # Sibling constraint from `call` wants:
          # a -> b
          # Combined: a -> b -> c -> a (cycle)
          def b
            c
          end

          def c
            a
          end

          def a; end
        end
      RUBY

      let(:offense_source) { <<~RUBY }
        class SiblingCycleExample
          def call
            a
            b
          end

          private

          # NOTE: Direct dependencies:
          # b -> c -> a
          # Sibling constraint from `call` wants:
          # a -> b
          # Combined: a -> b -> c -> a (cycle)
          def b
          ^^^^^ Define #b after #a to match the order they are called together. (Possible sibling cycle detected; autocorrect may be skipped.)
            c
          end

          def c
            a
          end

          def a; end
        end
      RUBY

      it 'registers a sibling offense and explains it may be cyclic (no autocorrect)' do
        expect_offense(offense_source, source: source)
        expect_no_corrections
      end
    end

    context 'with SkipCyclicSiblingEdges enabled' do
      let(:skip_cyclic_config) do
        RuboCop::Config.new(
          'SortedMethodsByCall/Waterfall' => { 'Enabled' => true, 'SkipCyclicSiblingEdges' => true }
        )
      end
      let(:config) { skip_cyclic_config }

      let(:source) { <<~RUBY }
        class SiblingCycleExample
          def call
            a
            b
          end

          private

          # Direct dependencies: b -> c -> a
          # If we enforced sibling "a -> b", we would get a cycle.
          def b
            c
          end

          def c
            a
          end

          def a; end
        end
      RUBY

      it 'does not enforce sibling edges that would introduce a cycle' do
        expect_no_offenses(source)
      end
    end
  end

  context 'with non-contiguous sections (nested classes, non-visibility sends)' do
    context 'with a nested class between methods' do
      let(:across_nested_source) { <<~RUBY }
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

      let(:across_nested_offense) { <<~RUBY }
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

      it 'does not autocorrect across a nested class' do
        expect_offense(across_nested_offense, source: across_nested_source)
        expect_no_corrections
      end
    end

    context 'with a contiguous section and a nested class below' do
      let(:contiguous_source) { <<~RUBY }
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

      let(:contiguous_corrected) { <<~RUBY }
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

      it 'autocorrects within a contiguous section and preserves a nested class below' do
        expect_offense(contiguous_source)
        expect_correction(contiguous_corrected)
      end
    end

    context 'with a non-visibility send between methods' do
      let(:non_vis_source) { <<~RUBY }
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

      let(:non_vis_offense) { <<~RUBY }
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

      it 'does not autocorrect across a non-visibility send' do
        expect_offense(non_vis_offense, source: non_vis_source)
        expect_no_corrections
      end
    end
  end
end
