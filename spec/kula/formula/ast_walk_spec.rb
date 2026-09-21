require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::AstWalk do
  # Case exposes switch/conditions/else, and each of those wraps its payload
  # again. Stopping at the wrappers left every node under a CASE invisible to
  # both the whitelist and the type checker, while reading as covered.
  it "reaches the expressions inside a CASE, not just its wrappers" do
    ast = Dentaku::Calculator.new.ast("CASE 1 WHEN 1 THEN 2 ELSE 3 END")
    seen = []
    described_class.each_node(ast) { |node| seen << node.class.name.split("::").last }

    expect(seen.count("Numeric")).to eq(4)
  end
end
