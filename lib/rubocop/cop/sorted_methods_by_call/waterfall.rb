# frozen_string_literal: true

module RuboCop
  module Cop
    module SortedMethodsByCall
      # Enforces "waterfall" ordering: define a method after any method
      # that calls it within the same scope. Produces a top-down reading flow
      # where orchestration appears before implementation details.
      #
      # - Scopes: class/module/sclass (top-level can be analyzed via on_begin)
      # - Offense: when a callee is defined above its caller
      # - Autocorrect: UNSAFE; reorders methods within a contiguous visibility section
      #   (does not cross other statements or nested scopes). Preserves leading
      #   doc comments on each method. Skips cycles and non-contiguous groups.
      #
      # Configuration
      # - AllowedRecursion [Boolean] (default: true)
      #     If true, the cop ignores violations that are part of a recursion cycle
      #     detectable in the direct call graph (callee → … → caller). If false,
      #     such cycles are reported.
      # - SafeAutoCorrect [Boolean] (default: false)
      #     Autocorrection is unsafe and only runs under -A, never under -a.
      # - SkipCyclicSiblingEdges [Boolean] (default: false)
      #     If true, the cop will not add "called together" sibling-order edges
      #     that would introduce a cycle with existing constraints (direct edges +
      #     already accepted sibling edges).
      #
      # @example Good (waterfall order)
      #   class Service
      #     def call
      #       foo
      #       bar
      #     end
      #
      #     private
      #
      #     def bar
      #       method123
      #     end
      #
      #     def method123
      #       foo
      #     end
      #
      #     def foo
      #       123
      #     end
      #   end
      #
      # @example Bad (violates waterfall order)
      #   class Service
      #     def call
      #       foo
      #       bar
      #     end
      #
      #     private
      #
      #     def foo
      #       123
      #     end
      #
      #     def bar
      #       method123
      #     end
      #
      #     def method123
      #       foo
      #     end
      #   end
      #
      # @see #analyze_scope
      # @see #try_autocorrect
      class Waterfall < ::RuboCop::Cop::Base # rubocop:disable Metrics/ClassLength
        include ::RuboCop::Cop::RangeHelp
        extend ::RuboCop::Cop::AutoCorrector

        VISIBILITY_METHODS = %i[private protected public].freeze

        # Template message for offenses where a callee appears before its caller.
        MSG = 'Define %<callee>s after its caller %<caller>s (waterfall order).'

        SIBLING_MSG = 'Define %<callee>s after %<caller>s to match the order they are called together.'

        MSG_CROSS_VISIBILITY_NOTE =
          '%<base>s (Autocorrect not supported across visibility boundaries: ' \
          '%<caller_visibility>s vs %<callee_visibility>s.)'

        MSG_SIBLING_CYCLE_NOTE =
          '%<base>s (Possible sibling cycle detected; autocorrect may be skipped.)'

        # Entry point for root :begin nodes (top-level).
        #
        # Whether top-level is analyzed depends on how the code is structured;
        # by default we only analyze class/module/sclass scopes, but top-level
        # is supported through this hook.
        #
        # @param node [RuboCop::AST::Node] root :begin node
        # @return [void]
        def on_begin(node)
          analyze_scope(node)
        end

        # Entry point for class scopes.
        #
        # @param node [RuboCop::AST::Node] :class node
        # @return [void]
        def on_class(node)
          analyze_scope(node)
        end

        # Entry point for module scopes.
        #
        # @param node [RuboCop::AST::Node] :module node
        # @return [void]
        def on_module(node)
          analyze_scope(node)
        end

        # Entry point for singleton class scopes (class << self).
        #
        # @param node [RuboCop::AST::Node] :sclass node
        # @return [void]
        def on_sclass(node)
          analyze_scope(node)
        end

        private

        def analyze_scope(scope_node)
          data = scope_data(scope_node)
          return unless data

          register_violation(data) if data[:edge]
          analyze_nested_scopes(data[:body])
        end

        def scope_data(scope_node)
          body = scope_body_nodes(scope_node)
          defs = method_def_nodes(body) if body.any?
          return unless defs && defs.size > 1

          names, name_set, idx = method_name_index(defs)
          direct = build_direct_edges(defs, name_set)
          sibling = build_sibling_edges(defs, name_set, direct, names)
          adj = build_adj(names, direct)

          type, edge = find_violation(direct, sibling, idx, adj)

          { body: body, idx: idx, defs: defs, names: names, edges: direct + sibling,
            type: type, edge: edge }
        end

        def register_violation(data)
          _, callee = data[:edge]
          add_offense(data[:defs][data[:idx].fetch(callee)], message: build_offense_message(
            violation_type: data[:type], violation: data[:edge], names: data[:names],
            edges_for_sort: data[:edges], body_nodes: data[:body]
          )) do |corrector|
            auto_correct_violation(corrector, data)
          end
        end

        def auto_correct_violation(corrector, data)
          try_autocorrect(corrector, data[:body], data[:defs], data[:edges], data[:edge])
        end

        # Return the direct "body statements" inside a scope node.
        #
        # @param node [RuboCop::AST::Node]
        # @return [Array<RuboCop::AST::Node>] direct children inside the scope body
        # @api private
        def scope_body_nodes(node)
          case node.type
          when :begin
            node.children
          when :class, :module, :sclass
            body = node.body
            return [] unless body

            body.begin_type? ? body.children : [body]
          else
            []
          end
        end

        # Select only method definition nodes from a scope body.
        #
        # @param body_nodes [Array<RuboCop::AST::Node>]
        # @return [Array<RuboCop::AST::Node>] :def/:defs nodes
        # @api private
        def method_def_nodes(body_nodes)
          # rubocop:disable Layout/LeadingCommentSpace
          body_nodes.select { |n| %i[def defs].include?(n.type) } #: Array[::RuboCop::AST::DefNode]
          # rubocop:enable Layout/LeadingCommentSpace
        end

        # Compute helper structures for method names in this scope.
        #
        # @param def_nodes [Array<RuboCop::AST::Node>]
        # @return [Array<(Array<Symbol>, Set<Symbol>, Hash{Symbol=>Integer})>]
        # @api private
        def method_name_index(def_nodes)
          names = def_nodes.map(&:method_name)
          [names, names.to_set, names.each_with_index.to_h]
        end

        # Build direct call edges (caller -> callee) for local calls within each method body.
        #
        # @param def_nodes [Array<RuboCop::AST::Node>]
        # @param names_set [Set<Symbol>]
        # @return [Array<Array(Symbol, Symbol)>]
        # @api private
        def build_direct_edges(def_nodes, names_set)
          def_nodes.flat_map do |def_node|
            local_calls(def_node, names_set)
              .reject { |callee| callee == def_node.method_name }
              .map { |callee| [def_node.method_name, callee] }
          end
        end

        # Build sibling-order edges (a -> b) for consecutive calls inside orchestration methods.
        #
        # Orchestration methods are those not called by any other method in this scope.
        #
        # @param def_nodes [Array<RuboCop::AST::Node>]
        # @param names_set [Set<Symbol>]
        # @param direct_edges [Array<Array(Symbol, Symbol)>]
        # @param names [Array<Symbol>]
        # @return [Array<Array(Symbol, Symbol)>]
        # @api private
        def build_sibling_edges(def_nodes, names_set, direct_edges, names)
          all_callees = direct_edges.to_set(&:last)
          direct_pair_set = direct_edges.to_set
          adj_for_siblings = build_adj(names, direct_edges)

          def_nodes.each_with_object([]) do |def_node, sibling_edges|
            next if all_callees.include?(def_node.method_name)

            sibling_edges.concat(sibling_edges_for_method(def_node, names_set, direct_pair_set, adj_for_siblings))
          end
        end

        def sibling_edges_for_method(def_node, names_set, direct_pair_set, adj_for_siblings)
          calls = local_calls(def_node, names_set)
          calls.each_cons(2).filter_map do |a, b|
            # @type var a: Symbol
            # @type var b: Symbol

            next if direct_pair_set.include?([a, b]) || direct_pair_set.include?([b, a])
            next if skip_cyclic_sibling_edges? && path_exists?(b, a, adj_for_siblings)

            adj_for_siblings[a] << b unless adj_for_siblings[a].include?(b)
            [a, b]
          end
        end

        # Find the first ordering violation. Checks direct edges first, then sibling edges.
        #
        # @param direct_edges [Array<Array(Symbol, Symbol)>]
        # @param sibling_edges [Array<Array(Symbol, Symbol)>]
        # @param index_of [Hash{Symbol=>Integer}]
        # @param adj_direct [Hash{Symbol=>Array<Symbol>}] adjacency list for direct edges
        # @return [Array<(Symbol, Array(Symbol, Symbol))>, Array<(nil, nil)>]
        # @api private
        def find_violation(direct_edges, sibling_edges, index_of, adj_direct)
          allow_recursion = allowed_recursion?

          violation = first_backward_edge(direct_edges, index_of, adj_direct, allow_recursion)
          return [:direct, violation] if violation

          violation = first_backward_edge(sibling_edges, index_of, adj_direct, allow_recursion)
          return [:sibling, violation] if violation

          nil
        end

        # Return the first backward edge found, optionally skipping edges that participate
        # in recursion/cycles detectable in the direct-call graph (AllowedRecursion).
        #
        # @param edges [Array<Array(Symbol, Symbol)>]
        # @param index_of [Hash{Symbol=>Integer}]
        # @param adj_direct [Hash{Symbol=>Array<Symbol>}] direct-call adjacency for path checks
        # @param allow_recursion [Boolean]
        # @return [Array(Symbol, Symbol), nil]
        # @api private
        def first_backward_edge(edges, index_of, adj_direct, allow_recursion)
          edges.find do |caller, callee|
            next unless index_of.key?(caller) && index_of.key?(callee)
            next if allow_recursion && path_exists?(callee, caller, adj_direct)

            index_of[callee] < index_of[caller]
          end
        end

        def build_offense_message(violation_type:, violation:, names:, edges_for_sort:, body_nodes:)
          caller_name, callee_name = violation

          base = base_message_for(violation_type, caller_name, callee_name)
          adj_all = build_adj(names, edges_for_sort)
          base = add_sibling_cycle_note_if_needed(base, violation_type, caller_name, callee_name, adj_all)
          add_cross_visibility_note_if_needed(base, body_nodes, caller_name, callee_name)
        end

        # @param violation_type [Symbol]
        # @param caller_name [Symbol]
        # @param callee_name [Symbol]
        # @return [String]
        # @api private
        def base_message_for(violation_type, caller_name, callee_name)
          if violation_type == :sibling
            format(SIBLING_MSG, callee: "##{callee_name}", caller: "##{caller_name}")
          else
            format(MSG, callee: "##{callee_name}", caller: "##{caller_name}")
          end
        end

        def add_sibling_cycle_note_if_needed(base_message, violation_type, caller_name, callee_name, adj_all)
          return base_message unless violation_type == :sibling

          if path_exists?(callee_name, caller_name, adj_all)
            format(MSG_SIBLING_CYCLE_NOTE, base: base_message)
          else
            base_message
          end
        end

        def add_cross_visibility_note_if_needed(base_message, body_nodes, caller_name, callee_name)
          sections = extract_visibility_sections(body_nodes)
          caller_vis = visibility_label(section_for_method(sections, caller_name))
          callee_vis = visibility_label(section_for_method(sections, callee_name))

          return base_message unless caller_vis != callee_vis

          format(MSG_CROSS_VISIBILITY_NOTE,
                 base: base_message,
                 caller_visibility: caller_vis,
                 callee_visibility: callee_vis)
        end

        def try_autocorrect(corrector, body_nodes, def_nodes, edges, initial_violation = nil)
          data = auto_correct_data(def_nodes, edges, initial_violation) or return
          target = section_containing(extract_visibility_sections(body_nodes), *data[:violation])
          return unless target && target[:defs].size > 1

          sorted = correction_order(target[:defs], data, data[:violation])
          return unless sorted

          replace_sorted_section(corrector, target[:defs], sorted)
        end

        def correction_order(defs, data, violation)
          names = defs.map(&:method_name)
          caller_name, callee_name = violation
          result = topo_sort(names, edges_for_section(data, names, caller_name, callee_name),
                             names.each_with_index.to_h)
          result == names ? nil : result
        end

        def auto_correct_data(def_nodes, edges, initial_violation)
          names = def_nodes.map(&:method_name)
          name_set = names.to_set
          direct = build_direct_edges(def_nodes, name_set)
          adj = build_adj(names, direct)
          violation = initial_violation || first_backward_edge(edges, names.each_with_index.to_h, adj,
                                                               allowed_recursion?)
          return unless violation

          { direct: direct, sibling: edges - direct, violation: violation }
        end

        def edges_for_section(data, section_names, caller_name, callee_name)
          direct = filter_names(data[:direct], section_names)
          sibling = filter_names(data[:sibling], section_names)
          direct = reject_reciprocal(direct) if allowed_recursion?
          data[:direct].any? { |u, v| u == caller_name && v == callee_name } ? direct : sibling + direct
        end

        def filter_names(edges, names)
          edges.select { |u, v| names.include?(u) && names.include?(v) }
        end

        def reject_reciprocal(edges)
          pair_set = edges.to_set
          edges.reject { |u, v| pair_set.include?([v, u]) }
        end

        def section_containing(sections, *method_names)
          sections.find do |section|
            section_names = section[:defs].map(&:method_name)
            method_names.all? { |name| section_names.include?(name) }
          end
        end

        def replace_sorted_section(corrector, defs, sorted_names)
          ranges = defs.to_h { |d| [d.method_name, range_with_leading_comments(d)] }
          content = sorted_names.map { |n| ranges.fetch(n).source }.join("\n\n")
          corrector.replace(bounds(ranges, defs), content)
        end

        def bounds(ranges, defs)
          range_between(defs.map { |d| ranges.fetch(d.method_name).begin_pos }.min,
                        defs.map { |d| ranges.fetch(d.method_name).end_pos }.max)
        end

        # Collect local method calls (receiver is nil/self) from within a def node,
        # restricted to known method names in this scope.
        #
        # @param def_node [RuboCop::AST::Node] :def or :defs
        # @param names_set [Set<Symbol>] known local method names in this scope
        # @return [Array<Symbol>] unique callee names
        # @api private
        def local_calls(def_node, names_set)
          body = def_node.body
          return [] unless body

          # @type var res: Array[Symbol]
          res = []
          body.each_node(:send) do |send|
            # @type var send: ::RuboCop::AST::SendNode
            recv = send.receiver
            next unless recv.nil? || recv&.self_type?

            mname = send.method_name
            res << mname if names_set.include?(mname)
          end
          res.uniq
        end

        # Build an adjacency list for a set of edges restricted to known names.
        #
        # @param names [Array<Symbol>]
        # @param edges [Array<Array(Symbol, Symbol)>]
        # @return [Hash{Symbol=>Array<Symbol>}] adjacency list
        # @api private
        def build_adj(names, edges)
          allowed = names.to_set
          # @type var adj: Hash[Symbol, Array[Symbol]]
          adj = Hash.new { |h, k| h[k] = [] }

          edges.each do |u, v|
            next unless allowed.include?(u) && allowed.include?(v)
            next if u == v

            adj[u] << v
          end

          adj
        end

        def path_exists?(src, dst, adj, limit = 200)
          # @type var visited: Hash[Symbol, bool]
          visited = {}
          queue = [src]
          limit.times do
            break if queue.empty?

            u = queue.shift
            visited[u] ? next : (visited[u] = true)
            return true if u == dst

            adj[u].each { |v| queue << v unless visited[v] }
          end
          false
        end

        def extract_visibility_sections(body_nodes)
          vis = nil
          body_nodes.slice_when { |_, b| not_def_node?(b) }.filter_map do |group|
            # @type var defs: Array[::RuboCop::AST::DefNode]
            defs = group.reject { |n| not_def_node?(n) }
            next if defs.empty?

            vis = vis_node(group) || vis
            make_section(vis, defs)
          end
        end

        def not_def_node?(node)
          !%i[def defs].include?(node.type)
        end

        def vis_node(group)
          group.find { |n| n.send_type? && bare_visibility_send?(n) }
        end

        def make_section(vis, defs)
          { visibility: vis, defs: defs, start_pos: defs.first.source_range.begin_pos,
            end_pos: defs.last.source_range.end_pos }
        end

        # Check if +node+ is a bare visibility modifier send:
        # `private`, `protected`, or `public` (with no args and no receiver).
        #
        # @param node [RuboCop::AST::Node]
        # @return [Boolean]
        # @api private
        def bare_visibility_send?(node)
          node.receiver.nil? &&
            VISIBILITY_METHODS.include?(node.method_name) &&
            node.arguments.empty?
        end

        # Find the visibility section containing a given method name.
        #
        # @param sections [Array<Hash>]
        # @param method_name [Symbol]
        # @return [Hash, nil]
        # @api private
        def section_for_method(sections, method_name)
          sections.find { |s| s[:defs].any? { |d| d.method_name == method_name } }
        end

        # Normalize a section to a string visibility label ("public", "private", "protected").
        #
        # @param section [Hash, nil]
        # @return [String]
        # @api private
        def visibility_label(section)
          return 'public' unless section # default visibility

          (section[:visibility]&.method_name || :public).to_s
        end

        def topo_sort(names, edges, idx_of)
          indegree, adj = graph(names, edges)
          queue = names.select { |n| indegree[n].zero? }.sort_by { |n| idx_of[n] }
          result = kahn_sort(indegree, adj, queue, idx_of)
          result.size == names.size ? result : nil
        end

        def kahn_sort(indegree, adj, queue, idx_of)
          # @type var result: Array[Symbol]
          result = []
          until queue.empty?
            result << (n = queue.shift)
            adj[n].each do |m|
              indegree[m] -= 1
              queue << m if indegree[m].zero?
            end
            queue.sort_by! { |x| idx_of[x] }
          end
          result
        end

        def graph(names, edges)
          indegree = Hash.new(0)
          # @type var adj: Hash[Symbol, Array[Symbol]]
          adj = Hash.new { |h, k| h[k] = [] }

          edges.each do |caller, callee|
            next unless names.include?(caller) && names.include?(callee)
            next if caller == callee

            adj[caller] << callee
            indegree[callee] += 1
          end

          names.each { |n| indegree[n] ||= 0 }

          [indegree, adj]
        end

        def range_with_leading_comments(node)
          buffer = processed_source.buffer
          expr = node.source_range

          start_line = (1...expr.line).reverse_each.reduce(expr.line) do |line, lineno|
            buffer.source_line(lineno) =~ /\A\s*#/ ? lineno : (break line)
          end

          range_between(buffer.line_range(start_line).begin_pos, expr.end_pos)
        end

        # Recurse into nested scopes inside the current scope body.
        #
        # @param body_nodes [Array<RuboCop::AST::Node>]
        # @return [void]
        # @api private
        def analyze_nested_scopes(body_nodes)
          body_nodes.each do |n|
            analyze_scope(n) if n.class_type? || n.module_type? || n.sclass_type?
          end
        end

        # Read config: AllowedRecursion (default true).
        #
        # @return [Boolean]
        # @api private
        def allowed_recursion?
          cop_config.fetch('AllowedRecursion') { true }
        end

        # Read config: SkipCyclicSiblingEdges (default false).
        #
        # @return [Boolean]
        # @api private
        def skip_cyclic_sibling_edges?
          cop_config.fetch('SkipCyclicSiblingEdges') { false }
        end
      end
    end
  end
end
