# frozen_string_literal: true

require "dentaku"
require "kula/formula/ast_walk"
require "kula/formula/catalog"
require "kula/formula/dependency_graph"
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
      def initialize(references: [], zone: Catalog::DEFAULT_ZONE)
        @resolver = Resolver.new(references)
        @zone = zone
      end

      attr_reader :resolver

      # +expected_type+ is the type the field this formula feeds can hold. Passing
      # nil skips the check, which is what a preview wants.
      def compile(source, expected_type: nil)
        over_budget = Limits.check(source)
        return Result.failure(source, over_budget) if over_budget.any?

        stored = @resolver.to_storage(source)
        ast = parse(stored)

        Result.new(
          source: source,
          stored: stored,
          dependencies: @resolver.dependencies(stored),
          diagnostics: dangling(stored) + unknown_functions(ast) + type_checker.check(ast, expected: expected_type),
          ast: ast
        )
      rescue Resolver::UnknownToken => e
        Result.failure(source, Diagnostic.new(code: Errors::UNKNOWN_FIELD, position: e.position, detail: {token: e.token}))
      rescue ::Dentaku::TokenizerError => e
        Result.failure(source, tokenizer_diagnostics(e))
      rescue ::Dentaku::ParseError => e
        Result.failure(source, parse_diagnostic(e))
      rescue ::Dentaku::ArgumentError => e
        # Dentaku::ArgumentError descends from ::ArgumentError, so it is not
        # covered by the rescues above. Named here so "compiling never raises"
        # holds by construction rather than by enumeration.
        Result.failure(source, Diagnostic.new(code: Errors::SYNTAX, detail: {message: e.message}))
      end

      # Evaluates an already-compiled formula, reporting why it could not: the
      # caller has to distinguish "waiting on a value" from "this formula is
      # broken", because those need different things said to the author.
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

      private

      def type_checker
        @type_checker ||= TypeChecker.new(@resolver.references)
      end

      def calculator
        @calculator ||= Catalog.install(::Dentaku::Calculator.new, zone: @zone)
      end

      # Through the calculator, not a bare parser: the parser needs the function
      # registry to know that ceiling() and the rest exist.
      def parse(stored)
        calculator.ast(stored)
      end

      # A handle typed directly rather than as {Token} never passes through the
      # rewrite, so it reaches storage unchecked. Without this it saves clean and
      # fails at evaluation as "not computable yet" — telling the author we are
      # waiting on a field that does not exist.
      def dangling(stored)
        @resolver.dangling(stored).map do |handle|
          Diagnostic.new(code: Errors::DANGLING_REFERENCE, detail: {handle: handle})
        end
      end

      # Installing onto a stock calculator leaves every dentaku built-in reachable
      # — sum, filter, left, and all of Math via RubyMath. Catalog::ALL is the
      # surface we document and support, so anything outside it is rejected here
      # rather than silently evaluating.
      def unknown_functions(ast)
        function_names(ast).reject { |name| Catalog::ALL.include?(name) }
          .uniq
          .map { |name| Diagnostic.new(code: Errors::UNKNOWN_FUNCTION, detail: {function: name}) }
      end

      def function_names(node)
        found = []
        AstWalk.each_node(node) do |current|
          found << current.class.name.to_s.split("::").last.downcase if current.is_a?(::Dentaku::AST::Function)
        end
        found
      end

      # A mistyped function name is not a syntax error, and the parser already
      # distinguishes them.
      def parse_diagnostic(error)
        code = (error.reason == :undefined_function) ? Errors::UNKNOWN_FUNCTION : Errors::SYNTAX
        Diagnostic.new(code: code, position: error.meta[:position], detail: function_detail(error))
      end

      def function_detail(error)
        named = error.meta[:function_name]
        named.nil? ? nil : {function: named}
      end

      def tokenizer_diagnostics(error)
        error.errors.map do |detail|
          Diagnostic.new(code: Errors::SYNTAX, position: detail[:position], detail: detail.compact)
        end
      end
    end
  end
end
