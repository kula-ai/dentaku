# frozen_string_literal: true

require "dentaku"
require "kula/formula/catalog"
require "kula/formula/errors"
require "kula/formula/limits"
require "kula/formula/resolver"
require "kula/formula/result"
require "kula/formula/type_checker"

module Kula
  module Formula
    # Turns what an author typed into something storable and evaluable, or into
    # the reasons it is neither.
    #
    #   compiler = Kula::Formula::Compiler.new(references: refs, zone: "Asia/Kolkata")
    #   result   = compiler.compile("{Base salary} * 1.1")
    #   result.stored        # => "f_412 * 1.1"
    #   result.dependencies  # => ["f_412"]
    #
    # Compiling never raises on bad input: a formula an author is halfway through
    # typing is the normal case, not an exception.
    class Compiler
      def initialize(references: [], zone: Catalog::DEFAULT_ZONE, limits: Limits.new)
        @resolver = Resolver.new(references)
        @zone = zone
        @limits = limits
      end

      attr_reader :resolver

      # +expected_type+ is the type the field this formula feeds can hold. Passing
      # nil skips the check, which is what a preview wants.
      def compile(source, expected_type: nil)
        over_budget = @limits.check(source)
        return Result.failure(source, over_budget) if over_budget.any?

        stored = @resolver.to_storage(source)
        ast = parse(stored)
        mismatched = type_checker.check(ast, expected: expected_type)

        Result.new(
          source: source,
          stored: stored,
          dependencies: @resolver.dependencies(stored),
          diagnostics: mismatched,
          ast: ast
        )
      rescue Resolver::UnknownToken => e
        Result.failure(source, Diagnostic.new(code: Errors::UNKNOWN_FIELD, position: e.position, detail: {token: e.token}))
      rescue ::Dentaku::TokenizerError => e
        Result.failure(source, tokenizer_diagnostics(e))
      rescue ::Dentaku::ParseError => e
        Result.failure(source, Diagnostic.new(code: Errors::SYNTAX, position: e.meta[:position]))
      end

      # Evaluates an already-compiled formula. Returns nil rather than raising
      # when a value it reads is missing — a formula over an unanswered field is
      # "not computable yet", not an error.
      def evaluate(stored, context = {})
        calculator.evaluate(stored, context)
      end

      # Same, but reports why it could not compute.
      def evaluate!(stored, context = {})
        [calculator.evaluate!(stored, context), nil]
      rescue ::Dentaku::ZeroDivisionError
        [nil, Diagnostic.new(code: Errors::DIVISION_BY_ZERO)]
      rescue ::Dentaku::UnboundVariableError => e
        [nil, Diagnostic.new(code: Errors::NOT_COMPUTABLE, detail: {unbound: Array(e.unbound_variables)})]
      rescue ::Dentaku::ArgumentError, ::Dentaku::Error
        # Dentaku::ArgumentError descends from ::ArgumentError rather than
        # Dentaku::Error, so it needs naming: it is what an operation over an
        # unanswered field raises, which is "not computable yet".
        [nil, Diagnostic.new(code: Errors::NOT_COMPUTABLE)]
      end

      def type_checker
        @type_checker ||= TypeChecker.new(@resolver.references)
      end

      def calculator
        @calculator ||= Catalog.install(::Dentaku::Calculator.new, zone: @zone)
      end

      # The graph over a whole scope, for cycle and ordering checks.
      def graph(edges, **options)
        DependencyGraph.new(edges, **options)
      end

      private

      # Through the calculator, not a bare parser: the parser needs the function
      # registry to know that ceiling() and the rest exist.
      def parse(stored)
        calculator.ast(stored)
      end

      def tokenizer_diagnostics(error)
        error.errors.map do |detail|
          Diagnostic.new(code: Errors::SYNTAX, position: detail[:position], detail: detail.compact)
        end
      end
    end
  end
end
