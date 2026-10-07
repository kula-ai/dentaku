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
      DATE_RESULT_FUNCTIONS = %w[today dateadd date parsedate now start_day end_day lastday].freeze

      # Registered with a fixed :numeric return type because dentaku's registry
      # wants one, but they actually pass their operands through. Taking that
      # declared type would reject coalesce({Job title}, "n/a") on a text field —
      # the most obvious "show a fallback when blank" formula there is.
      #
      PASS_THROUGH = %w[coalesce ifnull].freeze

      # max and min are NOT pass-through: they coerce every argument through
      # as_number and raise on text, so their result really is numeric. Treating
      # them as pass-through typed max({Title}, {Title}) as :string, which a text
      # field then accepted and which computes blank on every offer.
      #
      # The one thing the declared :numeric gets wrong is dates: an epoch is
      # carried as a number, so max(today(), today()) answered :numeric and put a
      # date in a number field. Date only when EVERY operand is one -- a mix is a
      # conflict, which is what comparing a date with a count already is.
      DATE_PRESERVING = %w[max min].freeze

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
          elsif date_preserving?(node)
            numeric_aggregate_type(children(node).map { |child| result_type(child) }.compact.uniq)
          elsif pass_through?(node)
            # Unified, not inferred: inferred_from_children answers nil when the
            # children disagree, and check() lets nil through as "cannot tell" --
            # so coalesce(1>0, 5) landed a boolean in a number field while the
            # same mix inside an if, which unifies, was refused. It also made
            # if(1=1, coalesce(1>0, 0), 0) pass, because the nil unified away.
            #
            # A pass-through answers one of its arguments, so disagreement is a
            # real conflict rather than ignorance.
            children(node).map { |child| result_type(child) }.reduce { |a, b| unify(a, b) }
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

      # max/min coerce every argument through as_number, so an operand they cannot
      # read is a conflict rather than a result type -- text or a boolean makes
      # the formula answer blank on every offer. An epoch is carried as a number,
      # so all-dates answers :date; a date mixed with a count is the same kind of
      # conflict date arithmetic already is.
      def numeric_aggregate_type(types)
        # Every other path propagates a conflicting child; this one answered
        # :numeric for it, which let coalesce(1>0, 5) back into a number field
        # one function up -- the exact smuggle the unify above closes.
        return CONFLICT if types.include?(CONFLICT)
        # A boolean never coerces, so it is a conflict. Text is NOT: as_number("7")
        # is 7, and a single-line field holding a number inside max computes fine
        # today, so whether an operand coerces is left to the argument-type check.
        # The result stays :numeric either way, which is what still refuses
        # max({Title}, {Title}) on a text field.
        return CONFLICT if types.include?(:logical)
        return :date if types == [:date]

        types.include?(:date) ? CONFLICT : :numeric
      end

      def date_preserving?(node)
        return false unless node.is_a?(::Dentaku::AST::Function)

        DATE_PRESERVING.include?(AstWalk.node_name(node))
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
