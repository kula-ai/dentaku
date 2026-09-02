# frozen_string_literal: true

module Kula
  module Formula
    # Translates between what a person types and what gets stored.
    #
    #   typed:  "{Base salary} * (1 + {Bonus %} / 100)"
    #   stored: "f_412 * (1 + f_413 / 100)"
    #
    # Storage is handle-based because the names people type are renamable: naming
    # a field differently must not break every formula reading it. The typed form
    # is re-rendered from the stored one, so a rename shows up everywhere at once.
    #
    # References are injected rather than looked up, so a formula can be compiled
    # against fields that do not exist yet — which matters when several proposed
    # fields reference one another.
    class Resolver
      # A field a formula may reference. +handle+ is stored, +token+ is what the
      # author types between braces.
      Reference = Struct.new(:handle, :token, :kind, keyword_init: true)

      TOKEN_PATTERN = /\{([^{}]+)\}/
      HANDLE_PATTERN = /\b([a-z]_[a-zA-Z0-9_]+)\b/
      # The same shape anchored, for validating a reference rather than scanning
      # a formula for one.
      EXACT_HANDLE = /\A[a-z]_[a-zA-Z0-9_]+\z/
      # Text between quotes is data, not syntax: a brace or a handle-shaped word
      # inside it must survive rewriting untouched and must never become a
      # dependency.
      LITERAL_PATTERN = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/

      # Raised when a typed token names no known field. Carries the offset so an
      # editor can underline it.
      class UnknownToken < StandardError
        attr_reader :token, :position

        def initialize(token, position)
          @token = token
          @position = position
          super("unknown field #{token.inspect}")
        end
      end

      # Raised when a reference cannot be used as written. Each of these is a
      # caller mistake that would otherwise surface as a formula silently reading
      # the wrong field, or no field at all.
      class InvalidReference < StandardError
        attr_reader :reference

        def initialize(reference, reason)
          @reference = reference
          super(reason)
        end
      end

      # Raised when two references normalise to the same token. Silently keeping
      # the last would make {Base salary} resolve to whichever the caller happened
      # to pass second, with no error and a formula reading the wrong field.
      class AmbiguousToken < StandardError
        attr_reader :token

        def initialize(token)
          @token = token
          super("more than one field is named #{token.inspect}")
        end
      end

      def initialize(references)
        @references = references.to_a
        @references.each { |reference| validate_reference!(reference) }

        @by_token = @references.each_with_object({}) do |ref, acc|
          key = normalize(ref.token)
          raise AmbiguousToken.new(ref.token) if acc.key?(key)

          acc[key] = ref
        end
        @by_handle = @references.each_with_object({}) do |ref, acc|
          raise InvalidReference.new(ref, "more than one field uses handle #{ref.handle.inspect}") if acc.key?(ref.handle)

          acc[ref.handle] = ref
        end
      end

      attr_reader :references

      # "{Base salary} * 2" -> "f_412 * 2"
      def to_storage(source)
        source.to_s.gsub(/#{LITERAL_PATTERN}|#{TOKEN_PATTERN}/) do |match|
          next match if literal?(match)

          token = ::Regexp.last_match(1)
          reference = @by_token[normalize(token)]
          raise UnknownToken.new(token, ::Regexp.last_match.begin(0)) if reference.nil?

          reference.handle
        end
      end

      # "f_412 * 2" -> "{Base salary} * 2". A handle whose field has since been
      # removed renders as the raw handle rather than vanishing, so the author can
      # see what broke.
      def to_display(stored)
        stored.to_s.gsub(/#{LITERAL_PATTERN}|#{HANDLE_PATTERN}/) do |match|
          next match if literal?(match)

          reference = @by_handle[match]
          reference ? "{#{reference.token}}" : match
        end
      end

      # Handles the formula reads, in first-appearance order. Persisting this
      # spares every later reader from re-parsing the source.
      def dependencies(stored)
        handles(stored).select { |handle| @by_handle.key?(handle) }
      end

      # Handles the formula reads that name nothing known — a removed field, or
      # one outside the author's scope.
      def dangling(stored)
        handles(stored).reject { |handle| @by_handle.key?(handle) }
      end

      # Blanks out quoted text so nothing inside it is read as syntax. Replaced
      # with spaces rather than removed so offsets do not shift for anything
      # downstream.
      def self.outside_literals(text)
        text.to_s.gsub(LITERAL_PATTERN) { |literal| " " * literal.length }
      end

      private

      # A handle the scanner cannot see is worse than a rejected one: the rewrite
      # still substitutes it, so the formula stores a reference that reports no
      # dependency and evaluates against nothing. A name containing a brace is
      # equally unusable, since to_display would produce something to_storage
      # cannot read back.
      def validate_reference!(reference)
        unless reference.handle.to_s.match?(EXACT_HANDLE)
          raise InvalidReference.new(reference, "handle #{reference.handle.inspect} is not a usable reference")
        end

        if reference.token.to_s.match?(/[{}]/)
          raise InvalidReference.new(reference, "field name #{reference.token.inspect} cannot contain braces")
        end
      end

      def handles(stored)
        self.class.outside_literals(stored).scan(HANDLE_PATTERN).flatten.uniq
      end

      def literal?(match)
        match.start_with?('"', "'")
      end

      # Tokens compare case- and whitespace-insensitively, so {base salary}
      # finds the field titled "Base Salary".
      def normalize(token)
        token.to_s.strip.downcase.squeeze(" ")
      end
    end
  end
end
