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

      module_function

      # Returns diagnostics; empty means within budget.
      def check(source)
        text = source.to_s
        found = []

        found << over(Errors::TOO_LONG, text.length, MAX_LENGTH) if text.length > MAX_LENGTH

        countable = Resolver.outside_literals(text)
        # Both notations count: an author types {Token}, an API client may submit
        # the handle form it was given, and the cap has to mean the same for each.
        references = countable.scan(Resolver::TOKEN_PATTERN).size +
          countable.scan(Resolver::HANDLE_PATTERN).size
        found << over(Errors::TOO_MANY_REFERENCES, references, MAX_REFERENCES) if references > MAX_REFERENCES

        depth = max_depth(countable)
        found << over(Errors::TOO_DEEPLY_NESTED, depth, MAX_NESTING) if depth > MAX_NESTING

        found
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
