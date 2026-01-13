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

        # Analyze a single scope node (:begin, :class, :module, :sclass):
        # - Collect method defs in the scope body
        # - Build direct call edges (caller → callee)
        # - Optionally build sibling-order edges ("called together")
        # - Find the first ordering violation and register an offense
        # - Attempt autocorrect (under -A) within a contiguous visibility section
        # - Recurse into nested scopes inside the body
        #
        # @param scope_node [RuboCop::AST::Node] a :begin, :class, :module, or :sclass node
        # @return [void]
        # @api private
        def analyze_scope(scope_node)
          body_nodes = scope_body_nodes(scope_node)
          return if body_nodes.empty?

          def_nodes = method_def_nodes(body_nodes)
          return if def_nodes.size <= 1

          names, names_set, index_of = method_name_index(def_nodes)

          direct_edges = build_direct_edges(def_nodes, names_set)
          sibling_edges = build_sibling_edges(def_nodes, names_set, direct_edges, names)

          edges_for_sort = direct_edges + sibling_edges
          adj_direct = build_adj(names, direct_edges)

          violation_type, violation = find_violation(direct_edges, sibling_edges, index_of, adj_direct)
          if violation
            _, callee_name = violation
            callee_node = def_nodes[index_of.fetch(callee_name)]

            message = build_offense_message(
              violation_type: violation_type,
              violation: violation,
              names: names,
              edges_for_sort: edges_for_sort,
              body_nodes: body_nodes
            )

            add_offense(callee_node, message: message) do |corrector|
              try_autocorrect(corrector, body_nodes, def_nodes, edges_for_sort, violation)
            end
          end

          analyze_nested_scopes(body_nodes)
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
          body_nodes.select { |n| %i[def defs].include?(n.type) }
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

          skip_cyclic_siblings = skip_cyclic_sibling_edges?
          adj_for_siblings = build_adj(names, direct_edges)

          sibling_edges = []

          def_nodes.each do |def_node|
            next if all_callees.include?(def_node.method_name)

            calls = local_calls(def_node, names_set)
            calls.each_cons(2) do |a, b|
              # If there is already a direct relationship between a and b (either direction),
              # do not add a sibling-order edge.
              next if direct_pair_set.include?([a, b]) || direct_pair_set.include?([b, a])

              # Optional: do not add a sibling edge that would introduce a cycle.
              next if skip_cyclic_siblings && path_exists?(b, a, adj_for_siblings)

              sibling_edges << [a, b]
              adj_for_siblings[a] << b unless adj_for_siblings[a].include?(b)
            end
          end

          sibling_edges
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

          [nil, nil]
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

        # Construct the final offense message, including optional notes:
        # - sibling cycle note (for sibling violations)
        # - cross-visibility note (public/private/protected boundary)
        #
        # @param violation_type [Symbol] :direct or :sibling
        # @param violation [Array(Symbol, Symbol)] (caller_name, callee_name)
        # @param names [Array<Symbol>]
        # @param edges_for_sort [Array<Array(Symbol, Symbol)>]
        # @param body_nodes [Array<RuboCop::AST::Node>]
        # @return [String]
        # @api private
        def build_offense_message(violation_type:, violation:, names:, edges_for_sort:, body_nodes:)
          caller_name, callee_name = violation

          base = base_message_for(violation_type, caller_name, callee_name)
          base = add_sibling_cycle_note_if_needed(base, violation_type, caller_name, callee_name, names, edges_for_sort)
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

        # Add a note when a sibling-order edge is part of a cycle in the combined graph.
        #
        # @param base_message [String]
        # @param violation_type [Symbol]
        # @param caller_name [Symbol]
        # @param callee_name [Symbol]
        # @param names [Array<Symbol>]
        # @param edges_for_sort [Array<Array(Symbol, Symbol)>]
        # @return [String]
        # @api private
        def add_sibling_cycle_note_if_needed(base_message, violation_type, caller_name, callee_name, names,
                                             edges_for_sort)
          return base_message unless violation_type == :sibling

          adj_all = build_adj(names, edges_for_sort)
          if path_exists?(callee_name, caller_name, adj_all)
            format(MSG_SIBLING_CYCLE_NOTE, base: base_message)
          else
            base_message
          end
        end

        # Add a note when the violation crosses visibility boundaries.
        #
        # @param base_message [String]
        # @param body_nodes [Array<RuboCop::AST::Node>]
        # @param caller_name [Symbol]
        # @param callee_name [Symbol]
        # @return [String]
        # @api private
        def add_cross_visibility_note_if_needed(base_message, body_nodes, caller_name, callee_name)
          sections = extract_visibility_sections(body_nodes)
          caller_section = section_for_method(sections, caller_name)
          callee_section = section_for_method(sections, callee_name)

          caller_vis = visibility_label(caller_section)
          callee_vis = visibility_label(callee_section)

          if caller_section && callee_section && caller_vis != callee_vis
            format(
              MSG_CROSS_VISIBILITY_NOTE,
              base: base_message,
              caller_visibility: caller_vis,
              callee_visibility: callee_vis
            )
          else
            base_message
          end
        end

        # UNSAFE autocorrect: reorder method definitions inside one contiguous visibility section only.
        #
        # This method intentionally does NOT reorder across:
        # - `private/protected/public` boundaries
        # - nested scopes
        # - non-visibility statements that break contiguity
        #
        # @param corrector [RuboCop::Cop::Corrector]
        # @param body_nodes [Array<RuboCop::AST::Node>]
        # @param def_nodes [Array<RuboCop::AST::Node>]
        # @param edges [Array<Array(Symbol, Symbol)>] direct + sibling edges for this scope
        # @param initial_violation [Array(Symbol, Symbol), nil]
        # @return [void]
        # @api private
        def try_autocorrect(corrector, body_nodes, def_nodes, edges, initial_violation = nil)
          sections = extract_visibility_sections(body_nodes)

          names     = def_nodes.map(&:method_name)
          names_set = names.to_set
          idx_of    = names.each_with_index.to_h

          # Recompute direct edges; split edges back into direct vs sibling
          direct_edges = build_direct_edges(def_nodes, names_set)
          sibling_edges = edges - direct_edges

          allow_recursion = allowed_recursion?
          adj_direct = build_adj(names, direct_edges)

          violation = initial_violation || first_backward_edge(edges, idx_of, adj_direct, allow_recursion)
          return unless violation

          caller_name, callee_name = violation

          target_section = sections.find do |section|
            section_names = section[:defs].map(&:method_name)
            section_names.include?(caller_name) && section_names.include?(callee_name)
          end
          return unless target_section

          defs = target_section[:defs]
          return if defs.size <= 1

          section_names  = defs.map(&:method_name)
          section_idx_of = section_names.each_with_index.to_h

          direct_violation = direct_edges.any? { |u, v| u == caller_name && v == callee_name }

          section_direct_edges  = direct_edges.select { |u, v| section_names.include?(u) && section_names.include?(v) }
          section_sibling_edges = sibling_edges.select { |u, v| section_names.include?(u) && section_names.include?(v) }

          if allow_recursion
            pair_set = section_direct_edges.to_set
            section_direct_edges = section_direct_edges.reject { |u, v| pair_set.include?([v, u]) }
          end

          section_edges_for_sort =
            if direct_violation
              section_direct_edges
            else
              section_sibling_edges + section_direct_edges
            end

          sorted_names = topo_sort(section_names, section_edges_for_sort, section_idx_of)
          return if sorted_names.nil? || sorted_names == section_names

          ranges_by_name = defs.to_h { |d| [d.method_name, range_with_leading_comments(d)] }
          sorted_def_sources = sorted_names.map { |n| ranges_by_name.fetch(n).source }

          visibility_node   = target_section[:visibility]
          visibility_source = visibility_node&.source.to_s

          new_content =
            if visibility_source.empty?
              sorted_def_sources.join("\n\n")
            else
              "#{visibility_source}\n\n#{sorted_def_sources.join("\n\n")}"
            end

          section_begin =
            if visibility_node
              visibility_node.source_range.begin_pos
            else
              defs.map { |d| range_with_leading_comments(d).begin_pos }.min
            end

          section_end = target_section[:end_pos]
          region = Parser::Source::Range.new(processed_source.buffer, section_begin, section_end)
          corrector.replace(region, new_content)
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

          res = []
          body.each_node(:send) do |send|
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
          adj = Hash.new { |h, k| h[k] = [] }

          edges.each do |u, v|
            next unless allowed.include?(u) && allowed.include?(v)
            next if u == v

            adj[u] << v
          end

          adj
        end

        # Breadth-first search to detect whether a path exists from +src+ to +dst+.
        #
        # @param src [Symbol]
        # @param dst [Symbol]
        # @param adj [Hash{Symbol=>Array<Symbol>}] adjacency list
        # @param limit [Integer] traversal safety limit
        # @return [Boolean]
        # @api private
        def path_exists?(src, dst, adj, limit = 200)
          return true if src == dst

          visited = {}
          q = [src]
          i = 0
          steps = 0

          while i < q.length
            steps += 1
            return false if steps > limit

            u = q[i]
            i += 1
            next if visited[u]

            visited[u] = true
            return true if u == dst

            adj[u].each { |v| q << v unless visited[v] }
          end

          false
        end

        # Split the scope body into contiguous sections of def/defs grouped
        # by the visibility modifier immediately preceding them (private/protected/public).
        #
        # A section is represented as a Hash with:
        # - :visibility [RuboCop::AST::Node, nil] the bare visibility send, or nil
        # - :defs [Array<RuboCop::AST::Node>] contiguous def/defs nodes
        # - :start_pos [Integer]
        # - :end_pos [Integer]
        #
        # @param body_nodes [Array<RuboCop::AST::Node>]
        # @return [Array<Hash>]
        # @api private
        def extract_visibility_sections(body_nodes)
          sections = []
          current_visibility = nil
          current_defs = []
          section_start = nil

          body_nodes.each_with_index do |node, idx|
            case node.type
            when :def, :defs
              current_defs << node
              section_start ||= node.source_range.begin_pos
            when :send
              flush_visibility_section!(sections, current_visibility, current_defs, section_start, body_nodes, idx - 1)
              current_defs = []
              section_start = nil
              current_visibility = node if bare_visibility_send?(node)
            else
              flush_visibility_section!(sections, current_visibility, current_defs, section_start, body_nodes, idx - 1)
              current_defs = []
              section_start = nil
              current_visibility = nil
            end
          end

          unless current_defs.empty?
            sections << {
              visibility: current_visibility,
              defs: current_defs,
              start_pos: section_start,
              end_pos: current_defs.last.source_range.end_pos
            }
          end

          sections
        end

        # Flush a currently-collected contiguous def/defs group into +sections+.
        #
        # @param sections [Array<Hash>]
        # @param current_visibility [RuboCop::AST::Node, nil]
        # @param current_defs [Array<RuboCop::AST::Node>]
        # @param section_start [Integer, nil]
        # @param body_nodes [Array<RuboCop::AST::Node>]
        # @param last_idx [Integer]
        # @return [void]
        # @api private
        def flush_visibility_section!(sections, current_visibility, current_defs, section_start, body_nodes, last_idx)
          return if current_defs.empty?

          sections << {
            visibility: current_visibility,
            defs: current_defs.dup,
            start_pos: section_start,
            end_pos: body_nodes[last_idx].source_range.end_pos
          }
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

        # Stable topological sort using the current definition order as a tie-breaker.
        #
        # @param names [Array<Symbol>]
        # @param edges [Array<Array(Symbol, Symbol)>]
        # @param idx_of [Hash{Symbol=>Integer}]
        # @return [Array<Symbol>, nil] sorted list, or nil if cycle prevents a full order
        # @api private
        def topo_sort(names, edges, idx_of)
          indegree = Hash.new(0)
          adj = Hash.new { |h, k| h[k] = [] }

          edges.each do |caller, callee|
            next unless names.include?(caller) && names.include?(callee)
            next if caller == callee

            adj[caller] << callee
            indegree[callee] += 1
            indegree[caller] ||= 0
          end

          names.each { |n| indegree[n] ||= 0 }

          queue = names.select { |n| indegree[n].zero? }.sort_by { |n| idx_of[n] }
          result = []

          until queue.empty?
            n = queue.shift
            result << n

            adj[n].each do |m|
              indegree[m] -= 1
              queue << m if indegree[m].zero?
            end

            queue.sort_by! { |x| idx_of[x] }
          end

          return nil unless result.size == names.size

          result
        end

        # Return a range that starts at the first contiguous comment line immediately
        # above the def/defs node and ends at the end of the def. This preserves
        # doc comments when methods are moved during autocorrect.
        #
        # @param node [RuboCop::AST::Node] :def or :defs
        # @return [Parser::Source::Range]
        # @api private
        def range_with_leading_comments(node)
          buffer = processed_source.buffer
          expr = node.source_range

          start_line = expr.line
          lineno = start_line - 1

          while lineno >= 1
            line = buffer.source_line(lineno)
            break unless line =~ /\A\s*#/

            start_line = lineno
            lineno -= 1
          end

          start_pos = buffer.line_range(start_line).begin_pos
          Parser::Source::Range.new(buffer, start_pos, expr.end_pos)
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
