# frozen_string_literal: true

module RuboCop
  module Cop
    module SortedMethodsByCall
      # +RuboCop::Cop::SortedMethodsByCall::Waterfall+ enforces "waterfall" ordering:
      # define a method after any method that calls it (within the same scope).
      #
      # - Scopes: class/module/sclass (top-level can be enabled in config)
      # - Offense: when a callee is defined above its caller
      # - Autocorrect: UNSAFE; reorders methods within a contiguous visibility section
      #
      # Example (good):
      #   def call
      #     foo
      #     bar
      #   end
      #
      #   private
      #
      #   def bar
      #     method123
      #   end
      #
      #   def method123
      #     foo
      #   end
      #
      #   def foo
      #     123
      #   end
      #
      # Example (bad):
      #   def foo
      #     123
      #   end
      #
      #   def call
      #     foo
      #   end
      #
      # Autocorrect (unsafe, opt-in via SafeAutoCorrect: false): topologically sorts the contiguous
      # block of defs to satisfy edges (caller -> callee). Skips cycles and non-contiguous groups.
      class Waterfall < ::RuboCop::Cop::Base # rubocop:disable Metrics/ClassLength
        include ::RuboCop::Cop::RangeHelp
        extend ::RuboCop::Cop::AutoCorrector

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall::MSG+ -> String
        #
        # Template message for offenses.
        MSG = 'Define %<callee>s after its caller %<caller>s (waterfall order).'

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#on_begin+ -> void
        #
        # Entry point for root :begin nodes (top-level). Whether it is analyzed
        # depends on configuration (e.g., CheckTopLevel). By default, only class/module scopes are analyzed.
        #
        # @param [RuboCop::AST::Node] node
        # @return [void]
        def on_begin(node)
          analyze_scope(node)
        end

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#on_class+ -> void
        #
        # Entry point for class scopes.
        #
        # @param [RuboCop::AST::Node] node
        # @return [void]
        def on_class(node)
          analyze_scope(node)
        end

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#on_module+ -> void
        #
        # Entry point for module scopes.
        #
        # @param [RuboCop::AST::Node] node
        # @return [void]
        def on_module(node)
          analyze_scope(node)
        end

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#on_sclass+ -> void
        #
        # Entry point for singleton class scopes (class << self).
        #
        # @param [RuboCop::AST::Node] node
        # @return [void]
        def on_sclass(node)
          analyze_scope(node)
        end

        private

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#analyze_scope+ -> void
        #
        # Collects defs in the current scope, builds caller->callee edges
        # for local sends, finds the first backward edge (callee defined before caller),
        # and registers an offense. If autocorrection is requested, attempts to reorder
        # methods within the same visibility section.
        #
        # @param [RuboCop::AST::Node] scope_node
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

          # FIX: collect callees correctly
          all_callees = direct_edges.map(&:last).to_set

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

          # Recurse into nested scopes
          body_nodes.each do |n|
            analyze_scope(n) if n.class_type? || n.module_type? || n.sclass_type?
          end
        end

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#scope_body_nodes+ -> Array<RuboCop::AST::Node>
        #
        # Normalizes a scope node to its immediate "body" items we iterate over.
        #
        # @param [RuboCop::AST::Node] node
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

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#local_calls+ -> Array<Symbol>
        #
        # Returns the set of local method names (receiver is nil/self) invoked inside
        # a given def node whose names exist in the provided name set.
        #
        # @param [RuboCop::AST::Node] def_node
        # @param [Set<Symbol>] names_set
        # @return [Array<Symbol>]
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

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#try_autocorrect+ -> void
        #
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
        # @param [RuboCop::Cop::Corrector] corrector
        # @param [Array<RuboCop::AST::Node>] body_nodes
        # @param [Array<RuboCop::AST::Node>] def_nodes
        # @param [Array<Array(Symbol, Symbol)>] edges
        # @return [void]
        #
        # @note Applied only when user asked for autocorrections; with SafeAutoCorrect: false, this runs under -A.
        # @note Also preserves contiguous leading doc comments above each method.
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

          # Rebuild section
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

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#build_adj+ -> Hash{Symbol=>Array<Symbol>}
        #
        # Builds an adjacency list for edges restricted to known names.
        #
        # @param [Array<Symbol>] names
        # @param [Array<Array(Symbol, Symbol)>] edges
        # @return [Hash{Symbol=>Array<Symbol>}]
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

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#first_backward_edge+ -> [Symbol, Symbol], nil
        #
        # Returns the first backward edge found, optionally skipping mutual recursion
        # if so configured.
        #
        # @param [Array<Array(Symbol, Symbol)>] edges
        # @param [Hash{Symbol=>Integer}] index_of
        # @param [Hash{Symbol=>Array<Symbol>}] adj
        # @param [Boolean] allow_recursion whether to ignore cycles
        # @return [[Symbol, Symbol], nil]
        def first_backward_edge(edges, index_of, adj, allow_recursion)
          edges.find do |caller, callee|
            next unless index_of.key?(caller) && index_of.key?(callee)
            # If mutual recursion allowed and there is a path callee -> caller, skip
            next if allow_recursion && path_exists?(callee, caller, adj)

            # Violation: callee is defined BEFORE caller (waterfall order)
            index_of[callee] < index_of[caller]
          end
        end

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#path_exists?+ -> Boolean
        #
        # Tests whether a path exists in the adjacency graph from +src+ to +dst+ (BFS).
        #
        # @param [Symbol] src
        # @param [Symbol] dst
        # @param [Hash{Symbol=>Array<Symbol>}] adj
        # @param [Integer] limit traversal step limit (guard)
        # @return [Boolean]
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

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#extract_visibility_sections+ -> Array<Hash>
        #
        # Splits the body into contiguous sections of defs grouped by the visibility
        # modifier immediately preceding them (private/protected/public). A section is:
        #   - :visibility -> the bare visibility node (send) or nil
        #   - :defs       -> contiguous def/defs nodes
        #   - :start_pos  -> begin_pos of the first def in the section
        #   - :end_pos    -> end_pos of the last def in the section
        #
        # Splits the body into contiguous sections of defs grouped by visibility modifier
        # (private/protected/public). Returns metadata for each section including:
        #   :visibility  -> visibility modifier node or nil
        #   :defs        -> array of def/defs nodes
        #   :start_pos   -> Integer (begin_pos)
        #   :end_pos     -> Integer (end_pos)
        #
        # @param [Array<RuboCop::AST::Node>] body_nodes
        # @return [Array<Hash{Symbol=>untyped}>]
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

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#topo_sort+ -> Array<Symbol>, nil
        #
        # Performs a stable topological sort using current order as a tie-breaker.
        #
        # @param [Array<Symbol>] names
        # @param [Array<Array(Symbol, Symbol)>] edges
        # @param [Hash{Symbol=>Integer}] idx_of
        # @return [Array<Symbol>, nil] sorted names or nil if a cycle prevents a full order
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

        # +RuboCop::Cop::SortedMethodsByCall::Waterfall#range_with_leading_comments+ -> Parser::Source::Range
        #
        # Returns a range that starts at the first contiguous comment line immediately
        # above the def/defs node, and ends at the end of the def. This preserves
        # YARD/RDoc doc comments when methods are moved during autocorrect.
        #
        # @param [RuboCop::AST::Node] node The def/defs node.
        # @return [Parser::Source::Range] Range covering leading comments + method body.
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
