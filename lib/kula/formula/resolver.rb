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

      def initialize(references)
        @references = references.to_a
        @by_token = @references.each_with_object({}) { |ref, acc| acc[normalize(ref.token)] = ref }
        @by_handle = @references.each_with_object({}) { |ref, acc| acc[ref.handle] = ref }
      end

      attr_reader :references

      # "{Base salary} * 2" -> "f_412 * 2"
      def to_storage(source)
        source.to_s.gsub(TOKEN_PATTERN) do
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
        stored.to_s.gsub(HANDLE_PATTERN) do
          handle = ::Regexp.last_match(1)
          reference = @by_handle[handle]
          reference ? "{#{reference.token}}" : handle
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

      def reference_for(handle)
        @by_handle[handle]
      end

      private

      def handles(stored)
        stored.to_s.scan(HANDLE_PATTERN).flatten.uniq
      end

      # Tokens compare case- and whitespace-insensitively, so {base salary}
      # finds the field titled "Base Salary".
      def normalize(token)
        token.to_s.strip.downcase.squeeze(" ")
      end
    end
  end
end
