# frozen_string_literal: true

require "kula/formula/errors"
require "kula/formula/resolver"

module Kula
  module Formula
    # Caps applied before a formula reaches the parser, so a hostile or careless
    # input is rejected cheaply rather than after the work of parsing it.
    #
    # Budgets are per-call rather than constants: saving a definition can afford
    # a stricter cap than an editor preview typed character by character.
    class Limits
      DEFAULTS = {
        max_length: 4_000,
        max_references: 50,
        max_nesting: 32
      }.freeze

      def initialize(**overrides)
        unknown = overrides.keys - DEFAULTS.keys
        raise ::ArgumentError, "unknown budget: #{unknown.join(", ")}" if unknown.any?

        @budget = DEFAULTS.merge(overrides)
      end

      attr_reader :budget

      # Returns diagnostics; empty means within budget.
      def check(source)
        text = source.to_s
        found = []

        found << over(Errors::TOO_LONG, text.length, :max_length) if text.length > @budget[:max_length]

        references = text.scan(Resolver::TOKEN_PATTERN).size
        found << over(Errors::TOO_MANY_REFERENCES, references, :max_references) if references > @budget[:max_references]

        depth = max_depth(text)
        found << over(Errors::TOO_DEEPLY_NESTED, depth, :max_nesting) if depth > @budget[:max_nesting]

        found
      end

      private

      def over(code, actual, key)
        Diagnostic.new(code: code, detail: {limit: @budget[key], actual: actual})
      end

      # Counted on the raw source rather than the AST: the point is to reject
      # before parsing, and a parser blows its stack on deep nesting.
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
    end
  end
end
