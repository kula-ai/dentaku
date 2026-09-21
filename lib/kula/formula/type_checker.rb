# frozen_string_literal: true

require "kula/formula/ast_walk"
require "kula/formula/resolver"
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
      # Dates and timestamps are stored as integer UNIX timestamps, but they are
      # NOT numbers: read as one, a salary lands in a date field as 1970-01-02
      # and an epoch lands in a currency field as a billion in money, both with
      # no diagnostic. A host that does not distinguish them can map its date
      # kinds to :numeric and get the old behaviour.
      TYPES = %i[numeric string logical date].freeze

      # Registered :numeric because dentaku's registry wants a type it knows, so
      # the date-ness is restored here — the alternative is teaching the registry
      # a type the gem ships no operators for.
      DATE_RESULT_FUNCTIONS = %w[today dateadd date].freeze

      # Registered with a fixed :numeric return type because dentaku's registry
      # wants one, but they actually pass their operands through. Taking that
      # declared type would reject coalesce({Job title}, "n/a") on a text field —
      # the most obvious "show a fallback when blank" formula there is.
      PASS_THROUGH = %w[coalesce ifnull].freeze

      # Returned when operands disagree, as distinct from nil "could not tell".
      # Collapsing the two lets if(c, {number}, {text}) satisfy any expected type,
      # since an unknown result is deliberately allowed through.
      CONFLICT = :__conflict__

      def initialize(references)
        @types = references.each_with_object({}) do |reference, acc|
          acc[Resolver.normalize_handle(reference.handle)] = normalize(reference.kind)
        end
      end

      # The type a formula produces, nil when it cannot be determined, or
      # CONFLICT when its parts disagree.
      def result_type(node)
        return nil if node.nil?

        case node
        when ::Dentaku::AST::Identifier
          @types[Resolver.normalize_handle(node.identifier)]
        when ::Dentaku::AST::If
          unify(result_type(node.left), result_type(node.right))
        when ::Dentaku::AST::Nil
          nil
        else
          # Arithmetic over a date is the trap this type exists for: `+` reports
          # itself numeric whatever it was given, so {joining date} + 90 compiled
          # green and moved the date by 90 SECONDS. Date arithmetic goes through
          # dateadd and datediff, which say what unit they mean.
          if date_arithmetic?(node)
            CONFLICT
          else
            declared(node) || inferred_from_children(node)
          end
        end
      end

      # Diagnostics for a formula whose result does not fit the field it feeds.
      def check(node, expected:)
        return [] if expected.nil?

        normalized = normalize(expected)
        # A caller asking for a type the language does not model is a bug in the
        # caller, not a formula the author can fix — say so rather than silently
        # checking nothing.
        raise ::ArgumentError, "unknown expected type #{expected.inspect}" if normalized.nil?

        expected = normalized

        actual = result_type(node)

        if actual == CONFLICT
          return [Diagnostic.new(code: Errors::RESULT_TYPE_MISMATCH, detail: {expected: expected, actual: :conflicting})]
        end

        # nil means "could not determine" — do not reject on a guess.
        return [] if actual.nil? || actual == expected

        [Diagnostic.new(
          code: Errors::RESULT_TYPE_MISMATCH,
          detail: {expected: expected, actual: actual}
        )]
      end

      private

      # No rescue: every #type in dentaku returns a literal or delegates, so the
      # blanket one this replaced was catching nothing. A type outside TYPES —
      # including a nil from a node that has no type — falls through to the
      # children walk, which is the fallback the rescue was reaching for anyway.
      def declared(node)
        return nil if pass_through?(node)
        return :date if date_result?(node)

        type = node.type if node.respond_to?(:type)
        TYPES.include?(type) ? type : nil
      end

      # An operation over references reports nil until its leaves are known, so
      # take the type its operands agree on.
      def inferred_from_children(node)
        types = children(node).map { |child| result_type(child) }.compact.uniq
        return CONFLICT if types.include?(CONFLICT)

        types.size == 1 ? types.first : nil
      end

      def date_result?(node)
        node.is_a?(::Dentaku::AST::Function) && DATE_RESULT_FUNCTIONS.include?(AstWalk.node_name(node))
      end

      def date_arithmetic?(node)
        return false unless node.is_a?(::Dentaku::AST::Arithmetic)

        children(node).any? { |child| result_type(child) == :date }
      end

      def pass_through?(node)
        return false unless node.is_a?(::Dentaku::AST::Function)

        PASS_THROUGH.include?(AstWalk.node_name(node))
      end

      def children(node)
        AstWalk.children(node)
      end

      def unify(left, right)
        return left if left == right
        return CONFLICT if [left, right].include?(CONFLICT)
        return right if left.nil?
        return left if right.nil?

        CONFLICT
      end

      def normalize(kind)
        return nil if kind.nil?

        symbol = kind.to_sym
        TYPES.include?(symbol) ? symbol : nil
      end
    end
  end
end
