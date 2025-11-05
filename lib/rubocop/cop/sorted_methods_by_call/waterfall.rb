# frozen_string_literal: true

module RuboCop
  module Cop
    module SortedMethodsByCall
      # Enforces "waterfall" ordering: a method must be defined after any method that calls it.
      #
      # Example (good):
      #   def foo
      #     bar
      #   end
      #
      #   def bar
      #     123
      #   end
      #
      # Example (bad):
      #   def bar
      #     123
      #   end
      #
      #   def foo
      #     bar
      #   end
      #
      # Autocorrect (unsafe, opt-in via SafeAutoCorrect: false): topologically sorts the contiguous
      # block of defs to satisfy edges (caller → callee). Skips cycles and non-contiguous groups.
      class Waterfall < ::RuboCop::Cop::Base
        include ::RuboCop::Cop::RangeHelp
        extend ::RuboCop::Cop::AutoCorrector

        MSG = "Define %<callee>s after its caller %<caller>s (waterfall order)."

        def on_begin(node)
          analyze_scope(node)
        end

        def on_class(node)
          analyze_scope(node)
        end

        def on_module(node)
          analyze_scope(node)
        end

        def on_sclass(node)
          analyze_scope(node)
        end

        private

        def analyze_scope(scope_node)
          body_nodes = scope_body_nodes(scope_node)
          return if body_nodes.empty?

          def_nodes = body_nodes.select { |n| n.def_type? || n.defs_type? }
          return if def_nodes.size <= 1

          names = def_nodes.map(&:method_name)
          names_set = names.to_set
          index_of = names.each_with_index.to_h

          edges = []
          def_nodes.each do |def_node|
            local_calls(def_node, names_set).each do |callee|
              next if callee == def_node.method_name # self-recursion

              edges << [def_node.method_name, callee]
            end
          end

          allow_recursion = cop_config.fetch("AllowedRecursion", true)
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

        def find_violation(edges, index_of)
          edges.find do |caller, callee|
            index_of.key?(caller) && index_of.key?(callee) && index_of[callee] < index_of[caller]
          end
        end

        # New helpers for mutual recursion handling
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

        def first_backward_edge(edges, index_of, adj, allow_recursion)
          edges.find do |caller, callee|
            next unless index_of.key?(caller) && index_of.key?(callee)
            # If mutual recursion allowed and there is a path callee -> caller, skip
            next if allow_recursion && path_exists?(callee, caller, adj)

            index_of[callee] < index_of[caller]
          end
        end

        # Unsafe autocorrect: reorder a contiguous def block if possible.
        def try_autocorrect(corrector, body_nodes, def_nodes, edges)
          return unless cop_config.fetch("SafeAutoCorrect", false) # require explicit opt-in

          # Only autocorrect when defs are contiguous within the body
          first_idx = body_nodes.index(def_nodes.first)
          last_idx = body_nodes.index(def_nodes.last)
          return unless first_idx && last_idx
          return unless body_nodes[first_idx..last_idx].all? { |n| n.def_type? || n.defs_type? }

          names = def_nodes.map(&:method_name)
          idx_of = names.each_with_index.to_h
          sorted_names = topo_sort(names, edges, idx_of)
          return unless sorted_names # cycle detected

          # Replace the whole block between first..last with the new order
          region = range_between(def_nodes.first.source_range.begin_pos, def_nodes.last.source_range.end_pos)
          name_to_node = def_nodes.each_with_object({}) { |d, h| h[d.method_name] = d }
          pieces = sorted_names.map { |n| name_to_node[n].source }
          corrector.replace(region, pieces.join("\n\n"))
        end

        # Topological sort with stable tie-breaking by current order.
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
      end
    end
  end
end
