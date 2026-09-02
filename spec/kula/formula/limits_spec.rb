require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::Limits do
  def codes(source, **budget)
    described_class.new(**budget).check(source).map(&:code)
  end

  it "passes a formula within budget" do
    expect(codes("{a} + {b}")).to be_empty
  end

  describe "length" do
    it "rejects a formula over the cap" do
      expect(codes("1" * 11, max_length: 10)).to eq([Kula::Formula::Errors::TOO_LONG])
    end

    it "allows one exactly at the cap" do
      expect(codes("1" * 10, max_length: 10)).to be_empty
    end

    it "reports the limit and the actual size" do
      detail = described_class.new(max_length: 10).check("1" * 11).first.detail

      expect(detail).to eq({limit: 10, actual: 11})
    end
  end

  describe "references" do
    it "rejects more references than the cap" do
      expect(codes("{a} + {b} + {c}", max_references: 2))
        .to eq([Kula::Formula::Errors::TOO_MANY_REFERENCES])
    end

    it "allows exactly the cap" do
      expect(codes("{a} + {b}", max_references: 2)).to be_empty
    end

    # An API client submits the handle form it was given, so the cap has to mean
    # the same for either notation.
    it "counts raw handles as well as braced tokens" do
      expect(codes("f_1 + f_2 + f_3", max_references: 2))
        .to eq([Kula::Formula::Errors::TOO_MANY_REFERENCES])
    end

    it "does not count a brace inside a string literal" do
      expect(codes(%{equaltext({a}, "{b}")}, max_references: 1)).to be_empty
    end
  end

  describe "nesting" do
    it "rejects nesting deeper than the cap" do
      expect(codes("((((1))))", max_nesting: 3))
        .to eq([Kula::Formula::Errors::TOO_DEEPLY_NESTED])
    end

    it "allows exactly the cap" do
      expect(codes("(((1)))", max_nesting: 3)).to be_empty
    end

    # Counted on raw source, before parsing, because a parser blows its stack on
    # deep nesting — which is the whole point of checking here.
    it "measures the deepest point, not the final balance" do
      expect(codes("((1)) + ((2))", max_nesting: 1))
        .to eq([Kula::Formula::Errors::TOO_DEEPLY_NESTED])
    end

    # A bracket inside quoted text is data, not nesting.
    it "ignores parentheses inside a string literal" do
      expect(codes(%{equaltext(a, "((((((")}, max_nesting: 2)).to be_empty
    end

    it "does not go negative on unbalanced closers" do
      expect(codes("1) + (2", max_nesting: 1)).to be_empty
    end
  end

  it "reports every cap a formula breaches" do
    expect(codes("{a} + {b} + ((((1))))", max_length: 5, max_references: 1, max_nesting: 2).size).to eq(3)
  end

  # A mistyped budget key silently doing nothing is worse than failing.
  it "refuses a budget key it does not know" do
    expect { described_class.new(max_lenght: 10) }.to raise_error(ArgumentError, /max_lenght/)
  end
end
