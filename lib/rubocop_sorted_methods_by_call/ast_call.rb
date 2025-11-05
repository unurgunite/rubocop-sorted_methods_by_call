# frozen_string_literal: true

require "parser/current"
require_relative "compare"
require_relative "extensions/util"

module RubocopSortedMethodsByCall
  # The +Processor+ class is corresponding for analyzing method
  # definition/call trace.
  class Processor < AST::Processor
    attr_reader :trace, :methods_list

    # +@methods_list+ Represents real AST nodes.
    # +@trace+ Represents expected AST nodes.
    # @return [Array]
    def initialize
      super
      @methods_list = {}
      @trace = {}
    end

    # +Processor#process(node)+                       -> value
    #
    # This method processes nodes during AST iterating.
    #
    # @overload process(node)
    # @param [AST::Node] node An object representing node.
    # @param [Symbol] name An object representing structure name.
    # @return [Object]
    #
    # @see Processor#on_def
    # @see AST::Processor#process
    def process(node, *name)
      return on_def(node, name[0]) if node.type == :def

      super(node)
    end

    # +Processor#on_begin(node)+                      -> Array
    #
    # This method is invoked when +Processor+ object encounters a +:begin+ AST
    # structure during tree parsing. It handles the root of AST, so we should
    # to iterate through its children to find out other nodes to get access to
    # their attributes.
    #
    # @api private
    # @overload on_begin(node)
    # @param [AST::Node] node An object representing node.
    # @return [Array]
    #
    # @see AST::Node#on_begin
    def on_begin(node, *name)
      name = name.first || :main
      node&.children&.each { |c| process(c, name) }
    end

    # +Processor#handler_missing(node)+               -> String
    #
    # This method is invoked when +Processor+ object encounters unhandled AST
    # structure. If there is no handler for node type, this method will be
    # invoked immediately.
    #
    # @api private
    # @overload handler_missing(node)
    # @param [AST::Node] node An object representing node.
    # @return [String, nil]
    #
    # @see AST::Node#handler_missing
    def handler_missing(node)
      puts "missing #{node.type}"
    end

    # +Processor#on_def(node)+                        -> Object
    #
    # This method is invoked when +Processor+ object encounters a +:def+ AST
    # node during tree parsing. It represents method definition in object's
    # message protocol. Current implementation of this handler processing method
    # names in real AST. It handles method names in trace when they are invoked
    # in single-line methods as well as with multi-line methods.
    #
    # @api private
    # @overload on_def(node)
    # @param [Object] node An object representing +:def+ node.
    # @raise [NoMethodError] if child is not a real node.
    # @return [Object]
    #
    # @see AST::Node#on_def
    def on_def(node, *name)
      name = name.first || :main
      @methods_list = Util.deep_merge(@methods_list, { name => node.children.first })

      invoked_methods = node.children[2]
      invoked_methods&.children&.each do |c|
        if c.is_a?(Symbol) && (invoked_methods.type != :lvar || c.type != :lvar)
          @trace = Util.deep_merge(@trace, { name => c })
          next
        end
        on_send(c, name) if c.type == :send
      rescue NoMethodError
        next
      end
    end

    # +Processor#on_send(node)+                       -> Array
    #
    # This method is invoked during +:send+ instruction during AST parsing.
    # According to Alan Kay's theory of object computation, each object can
    # receive and send messages to other objects representing objects in
    # real life. Ruby has the same object representation such as Smalltalk and
    # other message-oriented languages. Current method puts into array method
    # names in real AST.
    #
    # @api private
    # @overload on_send(node)
    # @param [Object] node An object representing +:send+ node.
    # @return [Hash]
    #
    # @see AST::Node#on_send
    def on_send(node, *name)
      @trace = Util.deep_merge(@trace, { name[0] || :main => node.children[1] })
    end

    # +Processor#on_class(node)+                      -> value
    #
    # This method is invoked during +:class+ instruction during AST parsing.
    # It evaluate class name and parse its methods.
    #
    # @api private
    # @overload on_class(node)
    # @param [AST::Node] node An object representing +:class+ node.
    # @return [Object]
    def on_class(node)
      class_name = :"class_#{node.children.first.children.last}"
      on_begin(node.children[2], class_name)
    end

    # +Processor#ordered?+                            -> TrueClass, FalseClass
    #
    # This method was made to check if methods in AST are defined in right order.
    # The right order in our case is defined by stack trace or by method call
    # position in other words. It compares real AST nodes with expected.
    #
    # @return [TrueClass, FalseClass]
    def ordered?
      RubocopSortedMethodsByCall::Compare.hashes_ordered_equal?(@methods_list, @trace)
    end
  end
end
