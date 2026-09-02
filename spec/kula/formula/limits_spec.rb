require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::Limits do
  def max_len = Kula::Formula::Limits::MAX_LENGTH

  def max_refs = Kula::Formula::Limits::MAX_REFERENCES

  def max_nest = Kula::Formula::Limits::MAX_NESTING

  def codes(source)
    described_class.check(source).map(&:code)
  end

  # n references as braced tokens, spaced so nothing else trips a cap.
  def refs(count)
    Array.new(count) { |i| "{a#{i}}" }.join(" + ")
  end

  def nested(depth)
    "(" * depth + "1" + ")" * depth
  end

  it "passes a formula within budget" do
    expect(codes("{a} + {b}")).to be_empty
  end

  describe "length" do
    it "rejects a formula over the cap" do
      expect(codes("1" * (max_len + 1))).to eq([Kula::Formula::Errors::TOO_LONG])
    end

    it "allows one exactly at the cap" do
      expect(codes("1" * max_len)).to be_empty
    end

    it "reports the limit and the actual size" do
      detail = described_class.check("1" * (max_len + 1)).first.detail

      expect(detail).to eq({limit: max_len, actual: max_len + 1})
    end
  end

  describe "references" do
    it "rejects more references than the cap" do
      expect(codes(refs(max_refs + 1))).to eq([Kula::Formula::Errors::TOO_MANY_REFERENCES])
    end

    it "allows exactly the cap" do
      expect(codes(refs(max_refs))).to be_empty
    end

    # An API client submits the handle form it was given, so the cap has to mean
    # the same for either notation.
    it "counts raw handles as well as braced tokens" do
      handles = Array.new(max_refs + 1) { |i| "f_#{i}" }.join(" + ")

      expect(codes(handles)).to eq([Kula::Formula::Errors::TOO_MANY_REFERENCES])
    end

    it "does not count a brace inside a string literal" do
      quoted = Array.new(max_refs + 1) { |i| %{"{a#{i}}"} }.join(", ")

      expect(codes("concat(#{quoted})")).to be_empty
    end
  end

  describe "nesting" do
    it "rejects nesting deeper than the cap" do
      expect(codes(nested(max_nest + 1))).to eq([Kula::Formula::Errors::TOO_DEEPLY_NESTED])
    end

    it "allows exactly the cap" do
      expect(codes(nested(max_nest))).to be_empty
    end

    # Counted on raw source, before parsing, because a parser blows its stack on
    # deep nesting — which is the whole point of checking here.
    it "measures the deepest point, not the final balance" do
      expect(codes("#{nested(max_nest + 1)} + #{nested(1)}"))
        .to eq([Kula::Formula::Errors::TOO_DEEPLY_NESTED])
    end

    # A bracket inside quoted text is data, not nesting.
    it "ignores parentheses inside a string literal" do
      expect(codes(%{equaltext(a, "#{"(" * (max_nest + 1)}")})).to be_empty
    end

    it "does not go negative on unbalanced closers" do
      expect(codes("1) + (2")).to be_empty
    end
  end

  it "reports every cap a formula breaches" do
    breaching = "#{refs(max_refs + 1)} + #{nested(max_nest + 1)}" + "1" * max_len

    expect(codes(breaching)).to match_array([
      Kula::Formula::Errors::TOO_LONG,
      Kula::Formula::Errors::TOO_MANY_REFERENCES,
      Kula::Formula::Errors::TOO_DEEPLY_NESTED
    ])
  end
end
