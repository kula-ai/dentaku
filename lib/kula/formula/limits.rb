# frozen_string_literal: true

require "kula/formula/errors"
require "kula/formula/resolver"

module Kula
  module Formula
    # Caps applied before a formula reaches the parser, so a hostile or careless
    # input is rejected cheaply rather than after the work of parsing it.
    module Limits
      MAX_LENGTH = 4_000
      MAX_REFERENCES = 50
      MAX_NESTING = 32
      # Binary operations in one formula. A chain of them is flat -- no
      # parentheses -- so MAX_NESTING measures zero for it, and it carries no
      # references so MAX_REFERENCES does not see it either. Only MAX_LENGTH
      # applied, and the operator-precedence parser recurses once per operator:
      # past some depth it exhausts the stack and the request answers 500 rather
      # than a diagnostic. Where that depth falls varies with how much stack is
      # left beneath the parse -- a Puma worker thread has far less than a console
      # -- which is the reason to cap the SOURCE rather than trust the stack.
      #
      # 200 against MAX_REFERENCES of 50. That is four times over for arithmetic
      # alone -- a formula naming the most fields it may needs about 49 operators
      # -- but the margin is smaller than four for a formula mixing kinds, because
      # comparison and logical operators count too: a tiered commission of ~20
      # nested ifs, each with a comparison, an `and` and two arithmetic operators,
      # reaches ~100 on its predicates before its results. Still well under any
      # depth observed to crash, and a refusal here is a diagnostic rather than a
      # 500 -- so if a real formula is ever refused, raise this with that formula
      # as the evidence rather than guessing upward now.
      #
      # Argument lists are not counted. They parse iteratively, so max(0, 0, ...)
      # with a thousand arguments is safe where the same count of binary operators
      # is not.
      MAX_OPERATIONS = 200

      # The binary operators the language offers -- arithmetic, bitwise, COMPARISON
      # and LOGICAL. Counted on the source with string literals already masked out,
      # so an operator an author typed inside quoted text is data rather than an
      # operation.
      #
      # Arithmetic and bitwise alone left the hole this cap exists to close: the
      # parser recurses once per binary node whatever the operator, so `1<1<1<1...`
      # and `a or a or a...` reached it uncounted, under MAX_LENGTH and naming no
      # fields.
      #
      # A minus is counted whatever it means: telling subtraction from negation
      # needs the tokenizer, and both recurse in the parser, so for a cap the
      # difference does not matter.
      #
      # Longest first, so `<=` is one operation rather than `<` and `=`. The word
      # operators are bounded, so a field token like {born_or_raised} is not three.
      OPERATION_PATTERN = %r{<=|>=|<>|!=|<<|>>|[+\-*/%^<>=&|]|\b(?:and|or|xor)\b}i

      module_function

      # Returns diagnostics; empty means within budget.
      def check(source)
        text = source.to_s
        found = []

        found << over(Errors::TOO_LONG, text.length, MAX_LENGTH) if text.length > MAX_LENGTH

        countable = Resolver.outside_literals(text)
        # Both notations count: an author types {Token}, an API client may submit
        # the handle form it was given, and the cap has to mean the same for each.
        # Handles counted only where a token did not already claim the text, or a
        # field literally named f_412 would count twice and the cap would mean
        # something different depending on what fields are called.
        # A token is an arbitrary field LABEL, so anything inside one is a name
        # rather than syntax: "{Sales and Marketing}" is not an `and`, "{R&D
        # Bonus}" not a `&`, "{Base - Variable}" not a minus. Counted over the
        # masked text, so the cap means the same thing whatever an account calls
        # its fields.
        unreferenced = countable.gsub(Resolver::TOKEN_PATTERN, " ")
        # Both notations count: an author types {Token}, an API client may submit
        # the handle form it was given, and the cap has to mean the same for each.
        # Handles counted only where a token did not already claim the text, or a
        # field literally named f_412 would count twice and the cap would mean
        # something different depending on what fields are called.
        references = countable.scan(Resolver::TOKEN_PATTERN).size +
          unreferenced.scan(Resolver::HANDLE_PATTERN).size
        found << over(Errors::TOO_MANY_REFERENCES, references, MAX_REFERENCES) if references > MAX_REFERENCES

        operations = unreferenced.scan(OPERATION_PATTERN).size
        found << over(Errors::TOO_DEEPLY_NESTED, operations, MAX_OPERATIONS) if operations > MAX_OPERATIONS

        depth = max_depth(countable)
        found << over(Errors::TOO_DEEPLY_NESTED, depth, MAX_NESTING) if depth > MAX_NESTING

        # One diagnostic per code. The operation cap and the nesting cap share
        # TOO_DEEPLY_NESTED, so a formula over both answered twice with the same
        # code and conflicting {limit} -- 200 and 32 -- and the editor renders one
        # message per code, so the admin was told whichever limit the client
        # happened to pick. The first is the one it reports.
        found.uniq(&:code)
      end

      def over(code, actual, limit)
        Diagnostic.new(code: code, detail: {limit: limit, actual: actual})
      end
      private_class_method :over

      # Counted on the source rather than the AST: the point is to reject before
      # parsing, and a parser blows its stack on deep nesting. Quoted text is
      # masked out first — a bracket an author typed inside a string is data, and
      # counting it rejects a formula that nests nothing.
      def max_depth(text)
        depth = 0
        deepest = 0

        text.each_char do |char|
          case char
          when "(" then deepest = [deepest, depth += 1].max
          when ")" then depth -= 1
          end
        end

        deepest
      end
      private_class_method :max_depth
    end
  end
end
