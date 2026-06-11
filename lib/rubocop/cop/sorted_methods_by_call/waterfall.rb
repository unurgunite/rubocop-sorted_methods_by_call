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

        # Entry point for top-level `:begin` scopes; delegates to `analyze_scope`.
        #
        # @param [RuboCop::AST::Node] node The `:begin` AST node representing the top-level scope.
        # @return [void]
        def on_begin(node)
          analyze_scope(node)
        end

        # Entry point for `:class` scopes; delegates to `analyze_scope`.
        #
        # @param [RuboCop::AST::Node] node The `:class` AST node to analyze.
        # @return [void]
        def on_class(node)
          analyze_scope(node)
        end

        # Entry point for `:module` scopes; delegates to `analyze_scope`.
        #
        # @param [RuboCop::AST::Node] node The `:module` AST node to analyze.
        # @return [void]
        def on_module(node)
          analyze_scope(node)
        end

        # Entry point for singleton class (`class << self`) scopes; delegates to `analyze_scope`.
        #
        # @param [RuboCop::AST::Node] node The `:sclass` AST node to analyze.
        # @return [void]
        def on_sclass(node)
          analyze_scope(node)
        end

        private

        # Analyze a scope node for waterfall ordering violations and recurse into nested scopes.
        #
        # @private
        # @param [RuboCop::AST::Node] scope_node The scope node (begin/class/module/sclass) to analyze.
        # @return [void]
        def analyze_scope(scope_node)
          data = scope_data(scope_node)
          return unless data

          register_violation(data) if data[:edge]
          analyze_nested_scopes(data[:body])
        end

        # Build a data hash with method definitions, edges, and the first violation (if any) for a scope.
        #
        # @private
        # @param [RuboCop::AST::Node] scope_node The scope node to extract data from.
        # @return [RuboCop::Cop::SortedMethodsByCall::Waterfall::data?]
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

        # Register an offense for the given violation data.
        #
        # @private
        # @param [RuboCop::Cop::SortedMethodsByCall::Waterfall::data] data The scope data hash containing violation and method information.
        # @return [void]
        def register_violation(data)
          _, callee = data[:edge]
          add_offense(data[:defs][data[:idx].fetch(callee)], message: build_offense_message(
            violation_type: data[:type], violation: data[:edge], names: data[:names],
            edges_for_sort: data[:edges], body_nodes: data[:body]
          )) do |corrector|
            auto_correct_violation(corrector, data)
          end
        end

        # Delegate autocorrection to `try_autocorrect` with violation data.
        #
        # @private
        # @param [RuboCop::Cop::Corrector] corrector The RuboCop corrector object used to apply corrections.
        # @param [RuboCop::Cop::SortedMethodsByCall::Waterfall::data] data The scope data hash containing edges and violation info.
        # @return [void]
        def auto_correct_violation(corrector, data)
          try_autocorrect(corrector, data[:body], data[:defs], data[:edges], data[:edge])
        end

        # Extract direct child nodes from a scope node's body.
        #
        # @private
        # @param [Object] node The scope node whose body children to extract.
        # @return [Array<RuboCop::AST::Node>]
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

        # Filter body nodes to only `:def`/`:defs` (method definition) nodes.
        #
        # @private
        # @param [Array<RuboCop::AST::Node>] body_nodes Array of child nodes from a scope body.
        # @return [Array<RuboCop::AST::DefNode>]
        def method_def_nodes(body_nodes)
          # rubocop:disable Layout/LeadingCommentSpace
          body_nodes.select { |n| %i[def defs].include?(n.type) } #: Array[::RuboCop::AST::DefNode]
          # rubocop:enable Layout/LeadingCommentSpace
        end

        # Build index structures: array of names, set of names, and name-to-position hash.
        #
        # @private
        # @param [Array<RuboCop::AST::DefNode>] def_nodes Array of method definition nodes to index.
        # @return [[ ::Array[::Symbol], ::Set[::Symbol], ::Hash[::Symbol, ::Integer] ]]
        def method_name_index(def_nodes)
          names = def_nodes.map(&:method_name)
          [names, names.to_set, names.each_with_index.to_h]
        end

        # Build direct call edges from each method definition to its local callees.
        #
        # @private
        # @param [Array<RuboCop::AST::DefNode>] def_nodes Array of method definition nodes to analyze.
        # @param [Set<Symbol>] names_set Set of known method names within the current scope.
        # @return [Array<[ ::Symbol, ::Symbol ]>]
        def build_direct_edges(def_nodes, names_set)
          def_nodes.flat_map do |def_node|
            local_calls(def_node, names_set)
              .reject { |callee| callee == def_node.method_name }
              .map { |callee| [def_node.method_name, callee] }
          end
        end

        # Build sibling call-order edges for orchestration methods.
        #
        # @private
        # @param [Array<RuboCop::AST::DefNode>] def_nodes Array of method definition nodes to analyze.
        # @param [Set<Symbol>] names_set Set of known method names within the current scope.
        # @param [Array<[ ::Symbol, ::Symbol ]>] direct_edges Previously computed direct call edges.
        # @param [Array<Symbol>] names Ordered array of method names in the current scope.
        # @return [Array<[ ::Symbol, ::Symbol ]>]
        def build_sibling_edges(def_nodes, names_set, direct_edges, names)
          all_callees = direct_edges.to_set(&:last)
          direct_pair_set = direct_edges.to_set
          adj_for_siblings = build_adj(names, direct_edges)

          def_nodes.each_with_object([]) do |def_node, sibling_edges|
            next if all_callees.include?(def_node.method_name)

            sibling_edges.concat(sibling_edges_for_method(def_node, names_set, direct_pair_set, adj_for_siblings))
          end
        end

        # Generate sibling edges for consecutive calls within a single method body.
        #
        # @private
        # @param [RuboCop::AST::DefNode] def_node The method definition node whose body to scan for consecutive calls.
        # @param [Set<Symbol>] names_set Set of known method names within the current scope.
        # @param [Set<[ ::Symbol, ::Symbol ]>] direct_pair_set Set of existing direct call pairs to avoid duplicating.
        # @param [Hash<Symbol, Array<Symbol>>] adj_for_siblings Adjacency map of existing edges for cycle detection.
        # @return [Array<[ ::Symbol, ::Symbol ]>]
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

        # Find the first backward edge in direct or sibling edges (waterfall order violation).
        #
        # @private
        # @param [Array<[ ::Symbol, ::Symbol ]>] direct_edges Direct call edges to check for violations.
        # @param [Array<[ ::Symbol, ::Symbol ]>] sibling_edges Sibling call-order edges to check for violations.
        # @param [Hash<Symbol, Integer>] index_of Map from method names to their definition position index.
        # @param [Hash<Symbol, Array<Symbol>>] adj_direct Adjacency map of direct edges for recursion cycle detection.
        # @return [[ ::Symbol, [ ::Symbol, ::Symbol ]? ]?]
        def find_violation(direct_edges, sibling_edges, index_of, adj_direct)
          allow_recursion = allowed_recursion?

          violation = first_backward_edge(direct_edges, index_of, adj_direct, allow_recursion)
          return [:direct, violation] if violation

          violation = first_backward_edge(sibling_edges, index_of, adj_direct, allow_recursion)
          return [:sibling, violation] if violation

          nil
        end

        # Find the first edge where callee is defined before caller, optionally skipping recursive cycles.
        #
        # @private
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges Edges to search for backward ordering.
        # @param [Hash<Symbol, Integer>] index_of Map from method names to their definition position index.
        # @param [Hash<Symbol, Array<Symbol>>] adj_direct Adjacency map for recursion cycle detection.
        # @param [Boolean] allow_recursion Whether to skip edges that are part of a recursive call cycle.
        # @return [[ ::Symbol, ::Symbol ]?]
        def first_backward_edge(edges, index_of, adj_direct, allow_recursion)
          edges.find do |caller, callee|
            next unless index_of.key?(caller) && index_of.key?(callee)
            next if allow_recursion && path_exists?(callee, caller, adj_direct)

            index_of[callee] < index_of[caller]
          end
        end

        # Build a full offense message with optional sibling-cycle and cross-visibility notes.
        #
        # @private
        # @param [Symbol] violation_type Either `:direct` or `:sibling` indicating the violation kind.
        # @param [[ ::Symbol, ::Symbol ]] violation The violating edge as a `[caller, callee]` pair.
        # @param [Array<Symbol>] names Ordered array of method names for adjacency construction.
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges_for_sort All edges in the scope used for building the full adjacency graph.
        # @param [Array<RuboCop::AST::Node>] body_nodes Body nodes of the scope for cross-visibility detection.
        # @return [String]
        def build_offense_message(violation_type:, violation:, names:, edges_for_sort:, body_nodes:)
          caller_name, callee_name = violation

          base = base_message_for(violation_type, caller_name, callee_name)
          adj_all = build_adj(names, edges_for_sort)
          base = add_sibling_cycle_note_if_needed(base, violation_type, caller_name, callee_name, adj_all)
          add_cross_visibility_note_if_needed(base, body_nodes, caller_name, callee_name)
        end

        # Return the base offense message template for a direct or sibling violation.
        #
        # @private
        # @param [Symbol] violation_type Either `:direct` or `:sibling`.
        # @param [Symbol] caller_name Name of the method that calls another.
        # @param [Symbol] callee_name Name of the method being called.
        # @return [String]
        def base_message_for(violation_type, caller_name, callee_name)
          if violation_type == :sibling
            format(SIBLING_MSG, callee: "##{callee_name}", caller: "##{caller_name}")
          else
            format(MSG, callee: "##{callee_name}", caller: "##{caller_name}")
          end
        end

        # Append a sibling-cycle warning note if applicable.
        #
        # @private
        # @param [String] base_message The base offense message to potentially annotate.
        # @param [Symbol] violation_type Either `:direct` or `:sibling`.
        # @param [Symbol] caller_name Name of the caller method.
        # @param [Symbol] callee_name Name of the callee method.
        # @param [Hash<Symbol, Array<Symbol>>] adj_all Full adjacency map for cycle detection.
        # @return [String]
        def add_sibling_cycle_note_if_needed(base_message, violation_type, caller_name, callee_name, adj_all)
          return base_message unless violation_type == :sibling

          if path_exists?(callee_name, caller_name, adj_all)
            format(MSG_SIBLING_CYCLE_NOTE, base: base_message)
          else
            base_message
          end
        end

        # Append a cross-visibility note if caller and callee are in different visibility sections.
        #
        # @private
        # @param [String] base_message The base offense message to potentially annotate.
        # @param [Array<RuboCop::AST::Node>] body_nodes Body nodes of the scope for visibility section extraction.
        # @param [Symbol] caller_name Name of the caller method.
        # @param [Symbol] callee_name Name of the callee method.
        # @return [String]
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

        # Attempt to autocorrect a violation by reordering methods within their visibility section.
        #
        # @private
        # @param [RuboCop::Cop::Corrector] corrector The RuboCop corrector object used to apply corrections.
        # @param [Array<RuboCop::AST::Node>] body_nodes Body nodes of the scope for visibility section extraction.
        # @param [Array<RuboCop::AST::DefNode>] def_nodes All method definition nodes in the scope.
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges All edges (direct + sibling) for the scope.
        # @param [[ ::Symbol, ::Symbol ]?] initial_violation The specific violating edge to autocorrect, or nil to auto-detect.
        # @return [void]
        def try_autocorrect(corrector, body_nodes, def_nodes, edges, initial_violation = nil)
          data = auto_correct_data(def_nodes, edges, initial_violation) or return
          target = section_containing(extract_visibility_sections(body_nodes), *data[:violation])
          return unless target && target[:defs].size > 1

          sorted = correction_order(target[:defs], data, data[:violation])
          return unless sorted

          replace_sorted_section(corrector, target[:defs], sorted)
        end

        # Compute the corrected method order via topological sort; returns nil if already correct.
        #
        # @private
        # @param [Array<RuboCop::AST::DefNode>] defs Method definition nodes in the target visibility section.
        # @param [RuboCop::Cop::SortedMethodsByCall::Waterfall::data] data Autocorrect data hash with direct, sibling edges, and violation.
        # @param [[ ::Symbol, ::Symbol ]] violation The violating `[caller, callee]` pair to resolve.
        # @return [Array<Symbol>?]
        def correction_order(defs, data, violation)
          names = defs.map(&:method_name)
          caller_name, callee_name = violation
          result = topo_sort(names, edges_for_section(data, names, caller_name, callee_name),
                             names.each_with_index.to_h)
          result == names ? nil : result
        end

        # Build data for autocorrection, recomputing direct edges and finding the violation.
        #
        # @private
        # @param [Array<RuboCop::AST::DefNode>] def_nodes All method definition nodes in the scope.
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges All edges (direct + sibling) for the scope.
        # @param [[ ::Symbol, ::Symbol ]?] initial_violation The specific violating edge, or nil to auto-detect.
        # @return [RuboCop::Cop::SortedMethodsByCall::Waterfall::data?]
        def auto_correct_data(def_nodes, edges, initial_violation)
          names = def_nodes.map(&:method_name)
          name_set = names.to_set
          direct = build_direct_edges(def_nodes, name_set)
          adj = build_adj(names, direct)
          violation = initial_violation || first_backward_edge(
            edges, names.each_with_index.to_h, adj, allowed_recursion?
          )
          return unless violation

          { direct: direct, sibling: edges - direct, violation: violation }
        end

        # Filter edges to those relevant to a given visibility section and violation.
        #
        # @private
        # @param [RuboCop::Cop::SortedMethodsByCall::Waterfall::data] data Autocorrect data hash with direct and sibling edge lists.
        # @param [Array<Symbol>] section_names Method names in the target visibility section.
        # @param [Symbol] caller_name Name of the caller method in the violation.
        # @param [Symbol] callee_name Name of the callee method in the violation.
        # @return [Array<[ ::Symbol, ::Symbol ]>]
        def edges_for_section(data, section_names, caller_name, callee_name)
          direct = filter_names(data[:direct], section_names)
          sibling = filter_names(data[:sibling], section_names)
          direct = reject_reciprocal(direct) if allowed_recursion?
          data[:direct].any? { |u, v| u == caller_name && v == callee_name } ? direct : sibling + direct
        end

        # Filter edges to only those whose both endpoints are in the given name list.
        #
        # @private
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges Edges to filter.
        # @param [Array<Symbol>] names Allowed method names; only edges between these names are kept.
        # @return [Array<[ ::Symbol, ::Symbol ]>]
        def filter_names(edges, names)
          edges.select { |u, v| names.include?(u) && names.include?(v) }
        end

        # Remove pairs of reciprocal edges (a→b, b→a) from the edge list.
        #
        # @private
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges Edges to filter reciprocal pairs from.
        # @return [Array<[ ::Symbol, ::Symbol ]>]
        def reject_reciprocal(edges)
          pair_set = edges.to_set
          edges.reject { |u, v| pair_set.include?([v, u]) }
        end

        # Find the visibility section that contains all given method names.
        #
        # @private
        # @param [Array<RuboCop::Cop::SortedMethodsByCall::Waterfall::section>] sections Visibility sections to search through.
        # @param [Array<Symbol>] method_names Method names to locate within a single section.
        # @return [RuboCop::Cop::SortedMethodsByCall::Waterfall::section?]
        def section_containing(sections, *method_names)
          sections.find do |section|
            section_names = section[:defs].map(&:method_name)
            method_names.all? { |name| section_names.include?(name) }
          end
        end

        # Replace the source code of a section of method definitions with the new sorted order.
        #
        # @private
        # @param [RuboCop::Cop::Corrector] corrector The RuboCop corrector object used to apply corrections.
        # @param [Array<RuboCop::AST::DefNode>] defs Method definition nodes in the section being reordered.
        # @param [Array<Symbol>] sorted_names Method names in their corrected order.
        # @return [void]
        def replace_sorted_section(corrector, defs, sorted_names)
          ranges = defs.to_h { |d| [d.method_name, range_with_leading_comments(d)] }
          content = sorted_names.map { |n| ranges.fetch(n).source }.join("\n\n")
          corrector.replace(bounds(ranges, defs), content)
        end

        # Compute a source range spanning all given method definitions by their stored ranges.
        #
        # @private
        # @param [Hash<Symbol, Object>] ranges Hash mapping method names to their source ranges (including leading comments).
        # @param [Array<RuboCop::AST::DefNode>] defs Method definition nodes whose span to compute.
        # @return [Parser::Source::Range]
        def bounds(ranges, defs)
          range_between(defs.map { |d| ranges.fetch(d.method_name).begin_pos }.min,
                        defs.map { |d| ranges.fetch(d.method_name).end_pos }.max)
        end

        # Collect local method calls (no receiver or self) within a method body that match known names.
        #
        # @private
        # @param [RuboCop::AST::DefNode] def_node The method definition node whose body to scan.
        # @param [Set<Symbol>] names_set Set of known method names to match against.
        # @return [Array<Symbol>]
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

        # Build an adjacency list (caller → [callees]) from edges, restricted to known names.
        #
        # @private
        # @param [Array<Symbol>] names Ordered array of method names to restrict the adjacency to.
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges Edges to build the adjacency list from.
        # @return [Hash<Symbol, Array<Symbol>>]
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

        # Check if a path exists from `src` to `dst` in the adjacency graph (BFS with limit).
        #
        # @private
        # @param [Symbol] src The starting node for the path search.
        # @param [Symbol] dst The target node to find a path to.
        # @param [Hash<Symbol, Array<Symbol>>] adj Adjacency map of the graph to search.
        # @param [Integer] limit Maximum number of iterations (nodes visited) for the BFS.
        # @return [Boolean]
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

        # Split body nodes into contiguous groups separated by non-def nodes, each with a visibility.
        #
        # @private
        # @param [Array<RuboCop::AST::Node>] body_nodes Body nodes of the scope to partition into visibility sections.
        # @return [Array<RuboCop::Cop::SortedMethodsByCall::Waterfall::section>]
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

        # Check if a node is NOT a `:def` or `:defs` node.
        #
        # @private
        # @param [Object] node The AST node to check.
        # @return [Boolean]
        def not_def_node?(node)
          !%i[def defs].include?(node.type)
        end

        # Find the visibility modifier node (`private`/`protected`/`public`) in a group of nodes.
        #
        # @private
        # @param [Array<RuboCop::AST::Node>] group A group of consecutive body nodes to search for a visibility modifier.
        # @return [RuboCop::AST::Node?]
        def vis_node(group)
          group.find { |n| n.send_type? && bare_visibility_send?(n) }
        end

        # Build a section hash with visibility, def nodes, and positional bounds.
        #
        # @private
        # @param [RuboCop::AST::Node?] vis The visibility modifier node (or nil for default public).
        # @param [Array<RuboCop::AST::DefNode>] defs Array of method definition nodes in this section.
        # @return [RuboCop::Cop::SortedMethodsByCall::Waterfall::section]
        def make_section(vis, defs)
          { visibility: vis, defs: defs, start_pos: defs.first.source_range.begin_pos,
            end_pos: defs.last.source_range.end_pos }
        end

        # Check if a node is a bare visibility modifier send (no receiver, no args).
        #
        # @private
        # @param [Object] node The AST node to check for bare visibility send pattern.
        # @return [Boolean]
        def bare_visibility_send?(node)
          node.receiver.nil? &&
            VISIBILITY_METHODS.include?(node.method_name) &&
            node.arguments.empty?
        end

        # Find the visibility section containing a given method name.
        #
        # @private
        # @param [Array<RuboCop::Cop::SortedMethodsByCall::Waterfall::section>] sections Visibility sections to search through.
        # @param [Symbol] method_name The method name to locate.
        # @return [RuboCop::Cop::SortedMethodsByCall::Waterfall::section?]
        def section_for_method(sections, method_name)
          sections.find { |s| s[:defs].any? { |d| d.method_name == method_name } }
        end

        # Convert a visibility section to a string label (`"public"`, `"private"`, `"protected"`).
        #
        # @private
        # @param [RuboCop::Cop::SortedMethodsByCall::Waterfall::section?] section The visibility section node (or nil for default public).
        # @return [String]
        def visibility_label(section)
          return 'public' unless section # default visibility

          (section[:visibility]&.method_name || :public).to_s
        end

        # Topologically sort names by edges; returns nil if a cycle exists.
        #
        # @private
        # @param [Array<Symbol>] names Ordered array of method names to sort.
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges Edges defining the dependency ordering constraints.
        # @param [Hash<Symbol, Integer>] idx_of Map from method names to their original position index for stable sorting.
        # @return [Array<Symbol>?]
        def topo_sort(names, edges, idx_of)
          indegree, adj = graph(names, edges)
          queue = names.select { |n| indegree[n].zero? }.sort_by { |n| idx_of[n] }
          result = kahn_sort(indegree, adj, queue, idx_of)
          result.size == names.size ? result : nil
        end

        # Kahn's algorithm for topological sort with stable tie-breaking by original index.
        #
        # @private
        # @param [Hash<Symbol, Integer>] indegree Map from node to its indegree count.
        # @param [Hash<Symbol, Array<Symbol>>] adj Adjacency list of the graph.
        # @param [Array<Symbol>] queue Initial queue of nodes with zero indegree, pre-sorted by original index.
        # @param [Hash<Symbol, Integer>] idx_of Map from method names to their original position index for stable sorting.
        # @return [Array<Symbol>]
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

        # Build indegree map and adjacency list from edges for topological sort.
        #
        # @private
        # @param [Array<Symbol>] names Ordered array of method names to include in the graph.
        # @param [Array<[ ::Symbol, ::Symbol ]>] edges Edges defining the dependency relationships.
        # @return [[ ::Hash[::Symbol, ::Integer], ::Hash[::Symbol, ::Array[::Symbol]] ]]
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

        # Expand a node's source range to include leading comment lines.
        #
        # @private
        # @param [RuboCop::AST::Node] node The AST node whose source range to expand.
        # @return [Parser::Source::Range]
        def range_with_leading_comments(node)
          buffer = processed_source.buffer
          expr = node.source_range

          start_line = (1...expr.line).reverse_each.reduce(expr.line) do |line, lineno|
            buffer.source_line(lineno) =~ /\A\s*#/ ? lineno : (break line)
          end

          range_between(buffer.line_range(start_line).begin_pos, expr.end_pos)
        end

        # Recursively analyze nested class/module/sclass scopes within body nodes.
        #
        # @private
        # @param [Array<RuboCop::AST::Node>] body_nodes Body nodes to scan for nested scope definitions.
        # @return [void]
        def analyze_nested_scopes(body_nodes)
          body_nodes.each do |n|
            analyze_scope(n) if n.class_type? || n.module_type? || n.sclass_type?
          end
        end

        # Read the `AllowedRecursion` config option (default true).
        #
        # @private
        # @return [Boolean]
        def allowed_recursion?
          cop_config.fetch('AllowedRecursion') { true }
        end

        # Read the `SkipCyclicSiblingEdges` config option (default false).
        #
        # @private
        # @return [Boolean]
        def skip_cyclic_sibling_edges?
          cop_config.fetch('SkipCyclicSiblingEdges') { false }
        end
      end
    end
  end
end
