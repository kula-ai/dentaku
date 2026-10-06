# frozen_string_literal: true

module Kula
  module Formula
    # A bounded set of codes, so a host can tag metrics and translate messages
    # without scattering string literals or leaking user content into either.
    module Errors
      SYNTAX = "err_formula_syntax"
      UNKNOWN_FIELD = "err_formula_unknown_field"
      DANGLING_REFERENCE = "err_formula_dangling_reference"
      SELF_REFERENCE = "err_formula_self_reference"
      CIRCULAR_REFERENCE = "err_formula_circular_reference"
      CHAIN_TOO_DEEP = "err_formula_chain_too_deep"
      TOO_LONG = "err_formula_too_long"
      TOO_MANY_REFERENCES = "err_formula_too_many_references"
      TOO_DEEPLY_NESTED = "err_formula_too_deeply_nested"
      # Its own code rather than TOO_DEEPLY_NESTED, which it used to share. A
      # chain of operations is FLAT -- it nests nothing -- so a host rendering one
      # message per code told the admin to remove nesting that is not there, and a
      # host branching on detail[:limit] instead would be matching the literal 200.
      TOO_MANY_OPERATIONS = "err_formula_too_many_operations"
      UNKNOWN_FUNCTION = "err_formula_unknown_function"
      UNSUPPORTED_CONSTRUCT = "err_formula_unsupported_construct"
      DIVISION_BY_ZERO = "err_formula_division_by_zero"
      NOT_COMPUTABLE = "err_formula_not_computable"
      RESULT_TYPE_MISMATCH = "err_formula_result_type"

      ALL = constants.map { |name| const_get(name) }.select { |value| value.is_a?(::String) }.freeze
    end

    # One thing wrong with a formula. +position+ is a character offset into the
    # source the author typed, or nil where the failure has no single site.
    Diagnostic = Struct.new(:code, :position, :detail, keyword_init: true) do
      def to_h
        {code: code, position: position, detail: detail}.compact
      end
    end
  end
end
