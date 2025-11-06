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

          names = def_nodes.map(&:method_name)
          names_set = names.to_set
          index_of = names.each_with_index.to_h

          # Build complete call graph - find ALL method calls in ALL methods
          edges = []
          def_nodes.each do |def_node|
            local_calls(def_node, names_set).each do |callee|
              next if callee == def_node.method_name # self-recursion

              edges << [def_node.method_name, callee]
            end
          end

          allow_recursion = cop_config.fetch('AllowedRecursion') { true }
          adj = build_adj(names, edges)

          violation = first_backward_edge(edges, index_of, adj, allow_recursion)
          return unless violation

          caller_name, callee_name = violation
          callee_node = def_nodes[index_of[callee_name]]

          add_offense(callee_node,
                      message: format(MSG, callee: "##{callee_name}", caller: "##{caller_name}")) do |corrector|
            try_autocorrect(corrector, body_nodes, def_nodes, edges)
          end

          # Recurse into nested scopes
          body_nodes.each { |n| analyze_scope(n) if n.class_type? || n.module_type? || n.sclass_type? }
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
        # @param [RuboCop::Cop::Corrector] corrector
        # @param [Array<RuboCop::AST::Node>] body_nodes
        # @param [Array<RuboCop::AST::Node>] def_nodes
        # @param [Array<Array(Symbol, Symbol)>] edges
        # @return [void]
        #
        # @note Applied only when user asked for autocorrections; with SafeAutoCorrect: false, this runs under -A.
        # @note Also preserves contiguous leading doc comments above each method.
        def try_autocorrect(corrector, body_nodes, def_nodes, edges)
          # Group method definitions into visibility sections
          sections = extract_visibility_sections(body_nodes)

          # Find the section that contains our violating methods
          caller_name, callee_name = first_backward_edge(
            edges,
            def_nodes.map(&:method_name).each_with_index.to_h,
            build_adj(def_nodes.map(&:method_name), edges),
            cop_config.fetch('AllowedRecursion') { true }
          )

          # No violation -> nothing to do
          return unless caller_name && callee_name

          # Find a visibility section that contains both names
          target_section = sections.find do |section|
            names_in_section = section[:defs].to_set(&:method_name)
            names_in_section.include?(caller_name) && names_in_section.include?(callee_name)
          end

          # If violation spans multiple sections, skip autocorrect
          return unless target_section

          defs = target_section[:defs]
          return unless defs.size > 1

          # Apply topological sort only within this visibility section
          names = defs.map(&:method_name)
          idx_of = names.each_with_index.to_h

          # Filter edges to only those within this section
          section_names = names.to_set
          section_edges = edges.select { |u, v| section_names.include?(u) && section_names.include?(v) }

          sorted_names = topo_sort(names, section_edges, idx_of)
          return unless sorted_names

          # Capture each def with its leading contiguous comment block
          ranges_by_name = defs.to_h { |d| [d.method_name, range_with_leading_comments(d)] }
          sorted_def_sources = sorted_names.map { |name| ranges_by_name[name].source }

          # Reconstruct the section: keep the visibility modifier (if any) above the first def
          visibility_node = target_section[:visibility]
          visibility_source = visibility_node&.source.to_s

          new_content = if visibility_source.empty?
                          sorted_def_sources.join("\n\n")
                        else
                          "#{visibility_source}\n\n#{sorted_def_sources.join("\n\n")}"
                        end

          # Expand the replaced region:
          # - if a visibility node exists, start from its begin_pos (so we replace it)
          # - otherwise, start from the earliest leading doc-comment of the defs
          section_begin =
            if visibility_node
              visibility_node.source_range.begin_pos
            else
              defs.map { |d| range_with_leading_comments(d).begin_pos }.min
            end

          # Always end at the end of the last def
          section_end = defs.last.source_range.end_pos

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
              # Check if this is a visibility modifier (private/protected/public)
              if node.receiver.nil? && %i[private protected public].include?(node.method_name) && node.arguments.empty?
                # End current section if it has defs
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
                current_visibility = node
              else
                # Non-visibility send - breaks contiguity
                unless current_defs.empty?
                  sections << {
                    visibility: current_visibility,
                    defs: current_defs.dup,
                    start_pos: section_start,
                    end_pos: body_nodes[idx - 1].source_range.end_pos
                  }
                  current_defs = []
                  section_start = nil
                  current_visibility = nil
                end
              end
            else
              # Any other node type breaks contiguity
              unless current_defs.empty?
                sections << {
                  visibility: current_visibility,
                  defs: current_defs.dup,
                  start_pos: section_start,
                  end_pos: body_nodes[idx - 1].source_range.end_pos
                }
                current_defs = []
                section_start = nil
                current_visibility = nil
              end
            end
          end

          # Handle trailing defs
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
