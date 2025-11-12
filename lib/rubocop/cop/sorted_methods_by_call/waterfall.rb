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
      #     If true, the cop ignores violations that are part of a mutual recursion
      #     cycle (callee → … → caller). If false, such cycles are reported.
      # - SafeAutoCorrect [Boolean] (default: false)
      #     Autocorrection is unsafe and only runs under -A, never under -a.
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

        # Template message for offenses where a callee appears before its caller.
        MSG = 'Define %<callee>s after its caller %<caller>s (waterfall order).'

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

        # Collects defs in the current scope, builds caller→callee edges for local sends,
        # locates the first backward edge (callee defined before caller), and registers
        # an offense. If autocorrection is requested, attempts to reorder methods within
        # the same visibility section.
        #
        # - Direct edges are used for recursion checks (AllowedRecursion).
        # - “Sibling” edges are added from orchestrator methods (not called by others)
        #   to reflect the order of consecutive calls (foo then bar).
        #
        # @param scope_node [RuboCop::AST::Node] a :begin, :class, :module, or :sclass node
        # @return [void]
        def analyze_scope(scope_node)
          body_nodes = scope_body_nodes(scope_node)
          return if body_nodes.empty?

          def_nodes = body_nodes.select { |n| %i[def defs].include?(n.type) }
          return if def_nodes.size <= 1

          names     = def_nodes.map(&:method_name)
          names_set = names.to_set
          index_of  = names.each_with_index.to_h

          # Phase 1: direct call edges (caller -> callee)
          direct_edges = def_nodes.flat_map do |def_node|
            calls = local_calls(def_node, names_set)
            calls.reject { |callee| callee == def_node.method_name }
                 .map    { |callee| [def_node.method_name, callee] }
          end

          # Methods that are called by someone else in this scope
          all_callees = direct_edges.to_set(&:last)

          # Phase 2: sibling-order edges from orchestration methods
          sibling_edges = []
          def_nodes.each do |def_node|
            next if all_callees.include?(def_node.method_name)

            calls = local_calls(def_node, names_set)
            calls.each_cons(2) do |a, b|
              next if direct_edges.any? { |u, v| (u == a && v == b) || (u == b && v == a) }

              sibling_edges << [a, b]
            end
          end

          # Phase 3: combine for sorting, but only use direct edges for recursion checks
          edges_for_sort   = direct_edges + sibling_edges
          allow_recursion  = cop_config.fetch('AllowedRecursion') { true }
          adj_direct       = build_adj(names, direct_edges)

          violation = first_backward_edge(direct_edges, index_of, adj_direct, allow_recursion)
          violation_type = :direct if violation

          unless violation
            violation = first_backward_edge(sibling_edges, index_of, adj_direct, allow_recursion)
            violation_type = :sibling if violation
          end

          return unless violation

          caller_name, callee_name = violation
          callee_node = def_nodes[index_of[callee_name]]

          message =
            if violation_type == :sibling
              "Define ##{callee_name} after ##{caller_name} to match the order they are called together"
            else
              format(MSG, callee: "##{callee_name}", caller: "##{caller_name}")
            end

          add_offense(callee_node, message: message) do |corrector|
            try_autocorrect(corrector, body_nodes, def_nodes, edges_for_sort, violation)
          end

          # Recurse into nested scopes inside this body
          body_nodes.each do |n|
            analyze_scope(n) if n.class_type? || n.module_type? || n.sclass_type?
          end
        end

        # Normalizes a scope node to its immediate "body" items we iterate over.
        #
        # @param node [RuboCop::AST::Node]
        # @return [Array<RuboCop::AST::Node>] direct children inside this scope
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

        # UNSAFE: Reorders method definitions inside the target visibility section only
        # (does not cross private/protected/public boundaries). Skips if defs are not
        # contiguous within the section or if a cycle prevents a consistent topo order.
        #
        # - Uses direct call edges for recursion checks.
        # - If the violation is a direct-call violation, sorts using only direct edges
        #   inside the section (so sibling edges cannot block the fix).
        # - If the violation is a sibling-order violation, includes sibling edges.
        # - Rewrites only the exact contiguous section (plus the visibility line if present).
        # - Preserves leading doc comments for each method.
        #
        # @param corrector [RuboCop::Cop::Corrector]
        # @param body_nodes [Array<RuboCop::AST::Node>] raw nodes of the scope body
        # @param def_nodes [Array<RuboCop::AST::Node>] all def/defs nodes in this body
        # @param edges [Array<Array(Symbol, Symbol)>] direct + sibling edges for this scope
        # @param initial_violation [Array<(Symbol, Symbol)>, nil] an already-found violating edge
        # @return [void]
        # @api private
        def try_autocorrect(corrector, body_nodes, def_nodes, edges, initial_violation = nil)
          sections = extract_visibility_sections(body_nodes)

          names  = def_nodes.map(&:method_name)
          idx_of = names.each_with_index.to_h
          names_set = names.to_set

          # Recompute direct edges; split edges back into direct vs sibling
          direct_edges = def_nodes.flat_map do |def_node|
            local_calls(def_node, names_set)
              .reject { |callee| callee == def_node.method_name }
              .map { |callee| [def_node.method_name, callee] }
          end
          sibling_edges = edges - direct_edges

          # Recursion check uses only direct edges
          allow_recursion = cop_config.fetch('AllowedRecursion') { true }
          adj_direct = build_adj(names, direct_edges)

          violation = initial_violation ||
                      first_backward_edge(edges, idx_of, adj_direct, allow_recursion)
          return unless violation

          caller_name, callee_name = violation

          # Find the contiguous section containing both caller and callee
          target_section = sections.find do |section|
            section_names = section[:defs].map(&:method_name)
            section_names.include?(caller_name) && section_names.include?(callee_name)
          end
          return unless target_section

          defs = target_section[:defs]
          return if defs.size <= 1

          section_names   = defs.map(&:method_name)
          section_idx_of  = section_names.each_with_index.to_h

          # Is this a direct-call violation?
          direct_violation = direct_edges.any? { |u, v| u == caller_name && v == callee_name }

          # Restrict edges to this contiguous section
          section_direct_edges  = direct_edges.select  { |u, v| section_names.include?(u) && section_names.include?(v) }
          section_sibling_edges = sibling_edges.select { |u, v| section_names.include?(u) && section_names.include?(v) }

          # Prune mutual-recursion edges inside the section if allowed
          if allow_recursion
            pair_set = section_direct_edges.to_set
            section_direct_edges = section_direct_edges.reject { |u, v| pair_set.include?([v, u]) }
          end

          # Sorting edges: direct-only for direct violation, otherwise sibling + pruned direct
          section_edges_for_sort =
            if direct_violation
              section_direct_edges
            else
              section_sibling_edges + section_direct_edges
            end

          sorted_names = topo_sort(section_names, section_edges_for_sort, section_idx_of)
          return if sorted_names.nil? || sorted_names == section_names

          # Rebuild section (preserve per-method leading docs)
          ranges_by_name = defs.to_h { |d| [d.method_name, range_with_leading_comments(d)] }
          sorted_def_sources = sorted_names.map { |n| ranges_by_name[n].source }

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

        # Collects local calls (receiver is nil/self) from within a def node
        # whose names are present in +names_set+.
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

        # Builds an adjacency list for edges restricted to known names.
        #
        # @param names [Array<Symbol>] method names
        # @param edges [Array<Array(Symbol, Symbol)>] caller→callee pairs
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

        # Returns the first backward edge found, optionally skipping edges
        # that participate in mutual recursion (when AllowedRecursion is true).
        #
        # @param edges [Array<Array(Symbol, Symbol)>] candidate edges to check
        # @param index_of [Hash{Symbol=>Integer}] current definition order (name -> index)
        # @param adj [Hash{Symbol=>Array<Symbol>}] direct-call adjacency for path checks
        # @param allow_recursion [Boolean] whether mutual recursion suppresses a violation
        # @return [(Symbol, Symbol), nil] the violating (caller, callee) or nil
        # @api private
        def first_backward_edge(edges, index_of, adj, allow_recursion)
          edges.find do |caller, callee|
            next unless index_of.key?(caller) && index_of.key?(callee)
            # If mutual recursion allowed and there is a path callee -> caller, skip
            next if allow_recursion && path_exists?(callee, caller, adj)

            # Violation: callee is defined BEFORE caller (waterfall order)
            index_of[callee] < index_of[caller]
          end
        end

        # Breadth-first search to detect if a path exists in the direct-call graph.
        #
        # @param src [Symbol] source method
        # @param dst [Symbol] destination method
        # @param adj [Hash{Symbol=>Array<Symbol>}] adjacency list
        # @param limit [Integer] traversal safety limit
        # @return [Boolean] true if a path exists
        # @api private
        def path_exists?(src, dst, adj, limit = 200)
          return true if src == dst

          visited = {}
          q = [src]
          steps = 0
          until q.empty?
            steps += 1
            return false if steps > limit

            u = q.shift
            next if visited[u]

            visited[u] = true
            return true if u == dst

            adj[u].each { |v| q << v unless visited[v] }
          end
          false
        end

        # Splits the scope body into contiguous sections of def/defs grouped
        # by the visibility modifier immediately preceding them (private/protected/public).
        #
        # A section is represented as a Hash with:
        # - :visibility [RuboCop::AST::Node, nil] the bare visibility send, or nil
        # - :defs [Array<RuboCop::AST::Node>] contiguous def/defs nodes
        # - :start_pos [Integer] begin_pos of the first def in the section
        # - :end_pos [Integer] end_pos of the last def in the section
        #
        # Non-visibility sends, constants, and nested scopes break contiguity.
        #
        # @param body_nodes [Array<RuboCop::AST::Node>] raw nodes in the scope body
        # @return [Array<Hash>] list of sections metadata
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
              # Close any running section before processing visibility/non-visibility send
              unless current_defs.empty?
                sections << {
                  visibility: current_visibility,
                  defs: current_defs.dup,
                  start_pos: section_start,
                  end_pos: body_nodes[idx - 1].source_range.end_pos
                }
                current_defs = []
                section_start = nil
              end

              # Bare visibility modifiers: private/protected/public without args
              if node.receiver.nil? && %i[private protected public].include?(node.method_name) && node.arguments.empty?
                current_visibility = node
              else
                # Non-visibility send breaks contiguity and resets visibility context
                current_visibility = nil
              end

            else
              # Any other node breaks contiguity and resets visibility context
              unless current_defs.empty?
                sections << {
                  visibility: current_visibility,
                  defs: current_defs.dup,
                  start_pos: section_start,
                  end_pos: body_nodes[idx - 1].source_range.end_pos
                }
                current_defs = []
                section_start = nil
              end
              current_visibility = nil
            end
          end

          # trailing defs
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

        # Stable topological sort using the current order as a tie-breaker.
        #
        # @param names [Array<Symbol>] names to sort
        # @param edges [Array<Array(Symbol, Symbol)>] caller→callee edges to respect
        # @param idx_of [Hash{Symbol=>Integer}] current order (name -> index)
        # @return [Array<Symbol>, nil] sorted names or nil if a cycle prevents a full order
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

        # Returns a range that starts at the first contiguous comment line immediately
        # above the def/defs node and ends at the end of the def. This preserves
        # YARD/RDoc doc comments when methods are moved during autocorrect.
        #
        # @param node [RuboCop::AST::Node] :def or :defs to capture with leading comments
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
      end
    end
  end
end
