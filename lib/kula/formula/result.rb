# frozen_string_literal: true

require "kula/formula/errors"

module Kula
  module Formula
    # What compiling a formula produced. Always answers `valid?`; the rest is
    # populated as far as compilation got.
    class Result
      attr_reader :source, :stored, :dependencies, :diagnostics, :ast

      def initialize(source:, stored: nil, dependencies: [], diagnostics: [], ast: nil)
        @source = source
        @stored = stored
        @dependencies = dependencies
        @diagnostics = diagnostics
        @ast = ast
      end

      def valid?
        diagnostics.empty?
      end

      def codes
        diagnostics.map(&:code)
      end

      def to_h
        {
          valid: valid?,
          source: source,
          stored: stored,
          dependencies: dependencies,
          diagnostics: diagnostics.map(&:to_h)
        }
      end

      def self.failure(source, *diagnostics)
        new(source: source, diagnostics: diagnostics.flatten)
      end
    end
  end
end
