require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::DependencyGraph do
  def build(edges, **options)
    described_class.new(edges, **options)
  end

  describe "#diagnostics" do
    it "is empty for a sound graph" do
      expect(build({"c" => %w[a b], "a" => [], "b" => []}).diagnostics).to be_empty
    end

    it "catches a formula reading itself" do
      result = build({"a" => %w[a]}).diagnostics

      expect(result.map(&:code)).to eq([Kula::Formula::Errors::SELF_REFERENCE])
    end

    it "catches a two-node cycle" do
      result = build({"a" => %w[b], "b" => %w[a]}).diagnostics

      expect(result.map(&:code)).to eq([Kula::Formula::Errors::CIRCULAR_REFERENCE])
    end

    it "catches a longer cycle" do
      result = build({"a" => %w[b], "b" => %w[c], "c" => %w[a]}).diagnostics

      expect(result.map(&:code)).to eq([Kula::Formula::Errors::CIRCULAR_REFERENCE])
      expect(result.first.detail[:handles]).to match_array(%w[a b c])
    end

    it "catches a reference to a field that is gone" do
      result = build({"a" => %w[missing]}).diagnostics(known: [])

      expect(result.map(&:code)).to eq([Kula::Formula::Errors::DANGLING_REFERENCE])
      expect(result.first.detail[:missing]).to eq("missing")
    end

    # Without a set of known handles there is nothing to compare against, so the
    # check is skipped rather than guessed at.
    it "skips the dangling check when the caller tracks no handles" do
      expect(build({"a" => %w[missing]}).diagnostics).to be_empty
    end

    it "catches a chain deeper than the budget" do
      edges = (1..5).each_with_object({}) { |n, acc| acc["f#{n}"] = ["f#{n + 1}"] }
      result = build(edges, max_chain: 3).diagnostics

      expect(result.map(&:code).uniq).to eq([Kula::Formula::Errors::CHAIN_TOO_DEEP])
    end
  end

  describe "#evaluation_order" do
    it "puts a formula after everything it reads" do
      order = build({"total" => %w[base bonus], "base" => [], "bonus" => %w[base]}).evaluation_order

      expect(order.index("base")).to be < order.index("bonus")
      expect(order.index("bonus")).to be < order.index("total")
    end
  end
end
