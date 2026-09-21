# frozen_string_literal: true

module Kula
  module Formula
    # Walking a parsed formula.
    #
    # Dentaku's AST nodes expose their operands under two different names —
    # +args+ on a function, +left+/+right+ on an operation — with no common
    # accessor, so anything traversing a tree has to know both. Kept in one
    # place so the type checker and the function check cannot drift apart on
    # what counts as a child.
    module AstWalk
      module_function

      def children(node)
        return [] if node.nil?

        if node.is_a?(::Dentaku::AST::Case)
          # Case exposes neither args nor left/right, so without this every node
          # underneath one is invisible to the whitelist and the type checker.
          [node.switch, *node.conditions, node.else].compact
        elsif node.is_a?(::Dentaku::AST::CaseConditional)
          [node.when, node.then].compact
        elsif node.respond_to?(:node) && node.node
          # CaseSwitchVariable, CaseWhen, CaseThen, CaseElse and Grouping each
          # wrap a single expression. Without this the walk stops at the wrapper
          # and the branches read as covered while nothing under them is seen.
          [node.node]
        elsif node.respond_to?(:args) && node.args
          Array(node.args)
        elsif node.respond_to?(:left)
          [node.left, (node.right if node.respond_to?(:right))].compact
        else
          []
        end
      end

      # A node's own name, downcased. Dentaku names a function class after the
      # function, so for an AST::Function this is its registration name — which is
      # what the whitelist and the type checker both rely on.
      def node_name(node)
        node.class.name.to_s.split("::").last.to_s.downcase
      end

      # Every node in the tree, parents before children.
      def each_node(node, &block)
        return if node.nil?

        block.call(node)
        children(node).each { |child| each_node(child, &block) }
      end
    end
  end
end
