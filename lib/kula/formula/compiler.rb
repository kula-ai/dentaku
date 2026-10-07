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
    # typing is the normal case, not an exception. A caller mistake still raises:
    # an unknown expected_type at check time, or colliding references at
    # construction.
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
          diagnostics:
            [unknown_identifiers(ast), unsupported_constructs(ast), unknown_functions(ast),
              variadic_arity(ast), invalid_units(ast), invalid_argument_types(ast),
              non_logical_conditions(ast), type_checker.check(ast, expected: expected_type)].flatten,
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
        # nil is a legitimate answer, not a failure: a two-arg if whose predicate
        # does not hold returns nil by design. The paths that genuinely cannot
        # compute raise instead, and are mapped below.
        [calculator.evaluate!(stored, context), nil]
      rescue ::Dentaku::ZeroDivisionError
        [nil, Diagnostic.new(code: Errors::DIVISION_BY_ZERO)]
      rescue ::Dentaku::UnboundVariableError => e
        [nil, Diagnostic.new(code: Errors::NOT_COMPUTABLE, detail: {unbound: Array(e.unbound_variables)})]
      rescue InvalidUnit => e
        # Before Dentaku::Error below, and its own code: a unit that arrives from
        # a FIELD cannot be refused at authoring, so this is the only place it can
        # be named -- and it has to be named the same way the compiler names a bad
        # literal, or the two disagree about the same mistake.
        [nil, Diagnostic.new(code: Errors::INVALID_UNIT,
          detail: {unit: e.unit.to_s, expects: Catalog::DATE_UNITS})]
      rescue ::Dentaku::ArgumentError
        # Descends from ::ArgumentError rather than Dentaku::Error, so it needs
        # naming: it is what an operation over an unanswered field raises.
        [nil, Diagnostic.new(code: Errors::NOT_COMPUTABLE)]
      rescue ::Dentaku::Error => e
        # Anything else is a broken formula, not one waiting on a value. Reporting
        # it as "not computable" would tell the author to do nothing.
        [nil, Diagnostic.new(code: Errors::SYNTAX, detail: {message: e.message})]
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
      #
      # Read off the AST rather than scanned out of the source, so a name that is
      # not handle-shaped — someone typing a field name without braces — is caught
      # by the same check.
      def unknown_identifiers(ast)
        names = []
        AstWalk.each_node(ast) do |node|
          names << node.identifier.to_s if node.is_a?(::Dentaku::AST::Identifier)
        end

        names.uniq.reject { |name| @resolver.known_handle?(name) }
          .map { |name| Diagnostic.new(code: Errors::DANGLING_REFERENCE, detail: {handle: name}) }
      end

      # Dentaku parses CASE unconditionally and it is not an AST::Function, so the
      # whitelist never sees it. It is not on the documented surface, and it is
      # untyped — Node#type is nil, so it satisfies any expected_type — so it is
      # rejected rather than left as an undocumented way in.
      # Case is parsed unconditionally by dentaku and is not an AST::Function, so
      # the whitelist never sees it. Exponentiation and the bitwise operators are
      # the same problem in operator form: they are not on the documented surface,
      # and `9^9^9^9` is nine characters that passes every budget in Limits and
      # then asks Ruby for a number with hundreds of millions of digits —
      # synchronously, wherever the host evaluates. Budgets bound the source, not
      # the result, so the operator has to go.
      # dateadd(timestamp, amount, unit) and datediff(later, earlier, unit): the
      # unit is the third argument in both.
      UNIT_FUNCTIONS = %w[dateadd datediff].freeze
      UNIT_ARGUMENT = 2

      UNSUPPORTED_NODES = [
        ::Dentaku::AST::Case,
        ::Dentaku::AST::Exponentiation,
        ::Dentaku::AST::BitwiseShiftLeft,
        ::Dentaku::AST::BitwiseShiftRight
      ].freeze

      def unsupported_constructs(ast)
        found = []
        AstWalk.each_node(ast) do |node|
          next unless UNSUPPORTED_NODES.any? { |klass| node.is_a?(klass) }

          found << Diagnostic.new(code: Errors::UNSUPPORTED_CONSTRUCT, detail: {construct: AstWalk.node_name(node)})
        end
        found.uniq(&:to_h)
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

      # The arity the parser could not check. Reported as SYNTAX, which is what a
      # fixed-arity function's wrong count already answers -- the same mistake
      # should not carry two codes depending on how the function happens to be
      # registered.
      def variadic_arity(ast)
        found = []
        AstWalk.each_node(ast) do |node|
          next unless node.is_a?(::Dentaku::AST::Function)

          name = AstWalk.node_name(node)
          allowed = Catalog::VARIADIC_ARITY[name]
          next if allowed.nil?

          given = AstWalk.children(node).size
          next if allowed.include?(given)

          found << Diagnostic.new(code: Errors::SYNTAX,
            detail: {function: name, given: given, expects: allowed})
        end
        found.uniq(&:to_h)
      end

      # A dateadd/datediff unit the readers do not know. Only a STRING LITERAL is
      # checked: a unit arriving from a field cannot be known while the admin is
      # typing, and guessing would refuse a formula that works. The literal is
      # the case reported -- a typo -- and the one authoring can do something
      # about.
      def invalid_units(ast)
        found = []
        AstWalk.each_node(ast) do |node|
          next unless node.is_a?(::Dentaku::AST::Function)

          name = AstWalk.node_name(node)
          next unless UNIT_FUNCTIONS.include?(name)

          unit = AstWalk.children(node)[UNIT_ARGUMENT]
          next unless unit.is_a?(::Dentaku::AST::String)
          next if Catalog::DATE_UNITS.include?(unit.value.to_s.downcase)

          found << Diagnostic.new(code: Errors::INVALID_UNIT,
            detail: {function: name, unit: unit.value.to_s, expects: Catalog::DATE_UNITS})
        end
        found.uniq(&:to_h)
      end

      # A literal where the reader wants a number. Only a literal: a field
      # reference cannot be known while the admin is typing, and a NUMERIC string
      # coerces deliberately -- dateadd(today(), "7", "days") computes the right
      # date and has to keep doing so.
      def invalid_argument_types(ast)
        found = []
        AstWalk.each_node(ast) do |node|
          next unless node.is_a?(::Dentaku::AST::Function)

          name = AstWalk.node_name(node)
          positions = Catalog::NUMERIC_ARGUMENTS[name]
          next if positions.nil?

          args = AstWalk.children(node)
          wanted = (positions == :all) ? (0...args.size) : positions
          wanted.each do |index|
            argument = args[index]
            next unless argument.is_a?(::Dentaku::AST::String)
            next if numeric_literal?(argument.value)

            found << Diagnostic.new(code: Errors::ARGUMENT_TYPE,
              detail: {function: name, argument: index + 1, value: argument.value.to_s})
          end
        end
        found.uniq(&:to_h)
      end

      # Asked the way the readers ask it, so the refusal cannot disagree with what
      # they would have accepted.
      def numeric_literal?(value)
        ::Kernel::BigDecimal(value.to_s)
        true
      rescue ::ArgumentError, ::TypeError
        false
      end

      # An if() whose condition is not a boolean. It used to answer THEN for any
      # of them -- 0 and "" included -- so the wrong branch computed into an
      # offer with nothing said. A type the checker cannot determine is left
      # alone, as everywhere else: never reject on a guess.
      def non_logical_conditions(ast)
        found = []
        AstWalk.each_node(ast) do |node|
          next unless node.is_a?(::Dentaku::AST::If)

          actual = type_checker.result_type(AstWalk.children(node).first)
          next if actual.nil? || actual == :logical || actual == TypeChecker::CONFLICT

          found << Diagnostic.new(code: Errors::CONDITION_NOT_LOGICAL, detail: {actual: actual})
        end
        found.uniq(&:to_h)
      end

      def function_names(node)
        found = []
        AstWalk.each_node(node) do |current|
          found << AstWalk.node_name(current) if current.is_a?(::Dentaku::AST::Function)
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
