# frozen_string_literal: true

require "kula/formula/catalog"
require "kula/formula/compiler"
require "kula/formula/dependency_graph"
require "kula/formula/errors"
require "kula/formula/limits"
require "kula/formula/resolver"
require "kula/formula/result"
require "kula/formula/type_checker"

# A formula language on top of dentaku: the function surface, the rewrite between
# author-facing names and stored handles, the caps, and the dependency graph.
#
# Everything here is pure Ruby with no persistence and no framework: a host
# application supplies the references and decides what to do with the result.
module Kula
  module Formula
  end
end
