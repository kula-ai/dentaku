# frozen_string_literal: true

require "tsort"
require "kula/formula/errors"

module Kula
  module Formula
    # The graph formed by every formula in a scope reading other fields.
    #
    # Answers three questions a host needs before saving a definition and again
    # before evaluating: does this cycle, does anything point at a field that is
    # gone, and in what order must these be computed.
    #
    # Edges come from persisted dependency lists rather than from re-parsing, so
    # the check stays cheap on a hot path.
    class DependencyGraph
      include ::TSort

      DEFAULT_MAX_CHAIN = 16

      # +edges+ maps a handle to the handles its formula reads.
      def initialize(edges, max_chain: DEFAULT_MAX_CHAIN)
        @edges = edges.transform_values { |deps| Array(deps) }
        @max_chain = max_chain
      end

      attr_reader :edges

      # Every problem with the graph, empty when it is sound.
      def diagnostics(known: nil)
        found = self_references + dangling(known) + cycles
        found.empty? ? deep_chains : found
      end

      # Handles in the order they must be computed: a formula never runs before
      # something it reads. Raises if the graph cycles, so check first.
      def evaluation_order
        tsort
      end

      def sound?(known: nil)
        diagnostics(known: known).empty?
      end

      # Handles whose formulas read the given one, directly or transitively.
      # This is what answers "what breaks if I change this field".
      #
      # Carries a visited set because a caller may reasonably ask this *before*
      # repairing a cycle — that is the natural order of operations, and without
      # the guard it recurses until SystemStackError, which is not a
      # StandardError and so escapes an ordinary rescue.
      def dependents_of(handle, seen = [])
        return [] if seen.include?(handle)

        # Memoised like chain_depth: on a diamond, many owners reading the same
        # few handles would otherwise revisit the shared subgraph once per path.
        @dependents ||= {}
        @dependents[handle] ||= begin
          onward = seen + [handle]
          readers.fetch(handle, []).flat_map { |owner| [owner] + dependents_of(owner, onward) }.uniq
        end
      end

      # Reverse index, built once: dependents_of would otherwise scan every edge
      # on every recursion.
      def readers
        @readers ||= @edges.each_with_object(::Hash.new { |h, k| h[k] = [] }) do |(owner, deps), acc|
          deps.each { |dep| acc[dep] << owner }
        end
      end

      def tsort_each_node(&block)
        @edges.each_key(&block)
      end

      def tsort_each_child(node, &block)
        @edges.fetch(node, []).each(&block)
      end

      private

      def self_references
        @edges.select { |owner, deps| deps.include?(owner) }
          .keys
          .map { |owner| Diagnostic.new(code: Errors::SELF_REFERENCE, detail: {handle: owner}) }
      end

      # +known+ nil means the caller is not tracking which handles exist, so
      # skip the check rather than guessing.
      def dangling(known)
        return [] if known.nil?

        known = known.to_a
        @edges.flat_map { |owner, deps|
          (deps - known - @edges.keys).map do |missing|
            Diagnostic.new(code: Errors::DANGLING_REFERENCE, detail: {handle: owner, missing: missing})
          end
        }
      end

      def cycles
        tsort
        []
      rescue ::TSort::Cyclic => e
        # TSort names the members in its message; report the set rather than
        # parsing that string.
        [Diagnostic.new(code: Errors::CIRCULAR_REFERENCE, detail: {handles: cycle_members, raw: e.message})]
      end

      def cycle_members
        each_strongly_connected_component.select { |component| component.size > 1 }.flatten
      end

      def deep_chains
        @edges.keys.filter_map do |owner|
          depth = chain_depth(owner)
          next if depth <= @max_chain

          Diagnostic.new(code: Errors::CHAIN_TOO_DEEP, detail: {handle: owner, depth: depth, limit: @max_chain})
        end
      end

      # Safe only once cycles are ruled out, which diagnostics guarantees by
      # returning early when any are found.
      def chain_depth(handle, seen = [])
        return 0 if seen.include?(handle)

        children = @edges.fetch(handle, [])
        return 0 if children.empty?

        # Memoised: a diamond where many handles read the same few would
        # otherwise revisit the shared subgraph once per path.
        @depths ||= {}
        @depths[handle] ||= 1 + children.map { |child| chain_depth(child, seen + [handle]) }.max
      end
    end
  end
end
