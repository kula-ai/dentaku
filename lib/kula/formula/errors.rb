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
      # dateadd/datediff take a unit, and advance/difference were a case with no
      # else -- so a typo'd one answered nil and authoring called the formula
      # valid. Its own code, because the unit and the set it had to be in are
      # what the author needs told, and only a detail can carry them.
      INVALID_UNIT = "err_formula_invalid_unit"
      # if() returned its THEN branch for ANY non-boolean condition, including 0
      # and "", so `if({salary}, "haspay", "nopay")` wrote "haspay" on a zero
      # salary. and/or already decline a non-boolean; this makes if agree.
      CONDITION_NOT_LOGICAL = "err_formula_condition_not_logical"
      # A literal where a reader wants a number -- dateadd's count, max's
      # operands. The readers raise on it, which evaluate reports as
      # NOT_COMPUTABLE, and the host renders that as "waiting on an input": so a
      # recruiter was sent to fill in a field because an admin had typed "five"
      # where a count goes. Refused at authoring instead, with the argument named.
      ARGUMENT_TYPE = "err_formula_argument_type"

      # A date handed to a text function. Dates are carried as epoch integers and
      # the language has no distinct date value, so at EVALUATION a text function
      # cannot tell today() from the number 1791331200 -- concat("Start: ",
      # today()) wrote the epoch into the offer letter and len(today()) answered
      # 10. The type checker does know, but only while compiling, so this is the
      # only place the author can be told. format_date is the remedy and is named
      # in the detail.
      DATE_NEEDS_FORMAT = "err_formula_date_needs_format"

      # `%` is two operators: infix modulo and postfix percentage. So `10 % -3`
      # is genuinely ambiguous -- "10 modulo -3" is -2 and "10 percent, minus 3"
      # is -2.9 -- and `50% - 3` is the same stream read the other way. The
      # parser refuses it, which is right: choosing a reading on the author's
      # behalf made `100000 * 10% - 500` evaluate to 0.0 in kula.17, a silently
      # wrong number in an offer letter, and was reverted in .18.
      #
      # Its own code only because err_formula_syntax told the author nothing and
      # the remedy -- parenthesise the half you mean -- is not discoverable.
      PERCENT_AMBIGUOUS = "err_formula_percent_ambiguous"
      NOT_COMPUTABLE = "err_formula_not_computable"
      RESULT_TYPE_MISMATCH = "err_formula_result_type"

      # Not a code: named here so the message and the refusal cannot drift.
      DATE_UNIT_MESSAGE = "day, week, month, year"

      ALL = constants.map { |name| const_get(name) }
        .select { |value| value.is_a?(::String) && value.start_with?("err_") }.freeze
    end

    # Raised by the date readers for a unit they do not know. Its own class so
    # evaluate! can answer the same code authoring does: mapped to
    # Dentaku::ArgumentError it became NOT_COMPUTABLE -- "waiting on an input" --
    # which sends the recruiter to fill in a field over an admin's typo.
    class InvalidUnit < ::Dentaku::Error
      attr_reader :unit, :function

      # Carries the function so the runtime diagnostic says what the authoring
      # one does -- the editor names both, and a reader that only knows the unit
      # cannot tell dateadd from datediff.
      def initialize(unit, function)
        @unit = unit
        @function = function
        super("#{function} must be one of #{Errors::DATE_UNIT_MESSAGE}")
      end
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
