require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::Limits do
  def max_len = Kula::Formula::Limits::MAX_LENGTH

  def max_refs = Kula::Formula::Limits::MAX_REFERENCES

  def max_nest = Kula::Formula::Limits::MAX_NESTING

  def max_ops = Kula::Formula::Limits::MAX_OPERATIONS

  # A flat chain of n binary operations: no parentheses, no references, so only
  # the operation cap can see it.
  def chain(count)
    "1" + ("+0" * count)
  end

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

  # A chain like this is flat, so the nesting cap measures zero for it, and it
  # names no fields, so the reference cap does not see it either. Only the length
  # cap applied, and the parser recurses once per operator -- past some depth it
  # exhausts the stack and the caller gets a 500 instead of a diagnostic.
  describe "operations" do
    it "rejects a chain over the cap" do
      expect(codes(chain(max_ops + 1))).to eq([Kula::Formula::Errors::TOO_DEEPLY_NESTED])
    end

    it "allows one exactly at the cap" do
      expect(codes(chain(max_ops))).to be_empty
    end

    # The operation cap and the nesting cap share TOO_DEEPLY_NESTED, so a formula
    # over both answered twice with the same code and conflicting limits -- 200
    # and 32 -- and the editor renders one message per code.
    it "answers one diagnostic per code when both caps are exceeded" do
      source = "(" * (max_nest + 8) + "1" + ("+1" * (max_ops + 50)) + ")" * (max_nest + 8)
      found = described_class.check(source)

      expect(found.map(&:code)).to eq([Kula::Formula::Errors::TOO_DEEPLY_NESTED])
      expect(found.first.detail).to eq({limit: max_ops, actual: max_ops + 50})
    end

    it "reports the limit and the actual count" do
      detail = described_class.check(chain(max_ops + 1)).first.detail

      expect(detail).to eq({limit: max_ops, actual: max_ops + 1})
    end

    # The chain from the report that prompted this cap.
    it "rejects the chain that reached the parser" do
      expect(codes(chain(1300))).to include(Kula::Formula::Errors::TOO_DEEPLY_NESTED)
    end

    # Argument lists parse iteratively, so a call with far more arguments than
    # this cap is safe where the same count of binary operators is not. Capping
    # them would refuse a formula that never had a problem.
    it "does not count a function's arguments" do
      expect(codes("max(" + (["0"] * (max_ops * 2)).join(",") + ")")).to be_empty
    end

    # An operator inside quoted text is data, as it is for the reference cap.
    it "does not count operators inside a string literal" do
      expect(codes(%{concat("#{"+" * (max_ops + 1)}", "a")})).to be_empty
    end

    # The parser recurses once per binary node whatever the operator, so counting
    # arithmetic alone left comparison and logical chains to reach it uncounted --
    # under the length cap and naming no fields, exactly like the arithmetic chain
    # this cap was written for.
    {
      "comparison" => "1" + ("<1" * 201),
      "two-character comparison" => "1" + ("<=1" * 201),
      "equality" => "1" + ("=1" * 201),
      "logical or" => "a" + (" or a" * 201),
      "logical and" => "a" + (" and a" * 201)
    }.each do |label, source|
      it "rejects a #{label} chain over the cap" do
        expect(codes(source)).to include(Kula::Formula::Errors::TOO_DEEPLY_NESTED)
      end
    end

    # A token is an arbitrary field LABEL, so an operator inside one is part of a
    # name. Counted, the cap meant something different depending on what an
    # account called its fields. The underscore forms below are NOT enough on
    # their own -- \b does not match inside born_or_raised, so that case passed
    # while the spaced and symbol ones were miscounted.
    it "does not count an operator inside a field name" do
      expect(codes("{born_or_raised} + {command_line} + {taxonomy}")).to be_empty
      expect(codes("{Sales and Marketing Target} + 1")).to be_empty
      expect(codes("{R&D Bonus} + 1")).to be_empty
      expect(codes("{Base - Variable} + 1")).to be_empty
      expect(codes("{Bonus %} + 1")).to be_empty
    end

    # A token's own operators must not eat the budget either: 100 tokens each
    # carrying an `and` is 0 operations, not 100.
    it "does not spend the budget on operators inside field names" do
      expect(codes(Array.new(100) { |i| "{Sales and Marketing #{i}}" }.join(" + "))).to eq(
        [Kula::Formula::Errors::TOO_MANY_REFERENCES]
      )
    end

    # Longest first: a two-character operator is one operation, not two.
    it "counts a two-character operator once" do
      expect(described_class.check("1" + ("<=1" * max_ops)).map(&:code)).to be_empty
    end
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
