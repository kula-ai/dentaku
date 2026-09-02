# frozen_string_literal: true

require "kula/formula/errors"

module Kula
  module Formula
    # Works out what a formula produces, so a field expecting a number is never
    # given one that returns text.
    #
    # Dentaku's AST already reports a type for literals, arithmetic, comparisons
    # and functions. The one thing it cannot know is what a field reference
    # yields, so this supplies those leaves from the injected references and
    # propagates the result upward.
    #
    # A type it cannot determine is nil, not an error: a formula over a field of
    # unknown kind should be allowed through rather than rejected on a guess.
    class TypeChecker
      # Dates and timestamps are stored as integer UNIX timestamps, so they are
      # numeric here. A host wanting stricter date typing can map them itself.
      TYPES = %i[numeric string logical].freeze

      # Registered with a fixed :numeric return type because dentaku's registry
      # wants one, but they actually pass their operands through. Taking that
      # declared type would reject coalesce({Job title}, "n/a") on a text field —
      # the most obvious "show a fallback when blank" formula there is.
      PASS_THROUGH = %w[coalesce ifnull].freeze

      def initialize(references)
        @types = references.each_with_object({}) do |reference, acc|
          acc[reference.handle] = normalize(reference.kind)
        end
      end

      # The type a formula produces, or nil when it cannot be determined.
      def result_type(node)
        return nil if node.nil?

        case node
        when ::Dentaku::AST::Identifier
          @types[node.identifier.to_s]
        when ::Dentaku::AST::If
          unify(result_type(node.left), result_type(node.right))
        when ::Dentaku::AST::Nil
          nil
        else
          declared(node) || inferred_from_children(node)
        end
      end

      # Diagnostics for a formula whose result does not fit the field it feeds.
      def check(node, expected:)
        expected = normalize(expected)
        return [] if expected.nil?

        actual = result_type(node)
        # nil means "could not determine" — do not reject on a guess.
        return [] if actual.nil? || actual == expected

        [Diagnostic.new(
          code: Errors::RESULT_TYPE_MISMATCH,
          detail: {expected: expected, actual: actual}
        )]
      end

      private

      def declared(node)
        return nil if pass_through?(node)

        type = node.type if node.respond_to?(:type)
        TYPES.include?(type) ? type : nil
      rescue ::StandardError
        # A node whose type depends on operands dentaku cannot resolve — fall
        # back to walking the children ourselves.
        nil
      end

      # An operation over references reports nil until its leaves are known, so
      # take the type its operands agree on.
      def inferred_from_children(node)
        types = children(node).map { |child| result_type(child) }.compact.uniq
        types.size == 1 ? types.first : nil
      end

      def pass_through?(node)
        return false unless node.is_a?(::Dentaku::AST::Function)

        PASS_THROUGH.include?(node.class.name.to_s.split("::").last.to_s.downcase)
      end

      def children(node)
        if node.respond_to?(:args) && node.args
          Array(node.args)
        elsif node.respond_to?(:left)
          [node.left, (node.right if node.respond_to?(:right))].compact
        else
          []
        end
      end

      def unify(left, right)
        return left if left == right
        return right if left.nil?
        return left if right.nil?

        nil
      end

      def normalize(kind)
        return nil if kind.nil?

        symbol = kind.to_sym
        TYPES.include?(symbol) ? symbol : nil
      end
    end
  end
end
