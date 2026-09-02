require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::Compiler do
  subject(:compiler) { described_class.new(references: references, zone: "UTC") }

  let(:ref) { Kula::Formula::Resolver::Reference }
  let(:references) do
    [
      ref.new(handle: "f_412", token: "Base salary", kind: :numeric),
      ref.new(handle: "f_413", token: "Bonus %", kind: :numeric),
      ref.new(handle: "s_title", token: "Job title", kind: :string)
    ]
  end

  describe "#compile" do
    it "stores the handle form and records what it reads" do
      result = compiler.compile("{Base salary} * (1 + {Bonus %} / 100)")

      expect(result).to be_valid
      expect(result.stored).to eq("f_412 * (1 + f_413 / 100)")
      expect(result.dependencies).to eq(%w[f_412 f_413])
    end

    it "reports an unknown field with its position rather than raising" do
      result = compiler.compile("{Base salary} + {Nonsense}")

      expect(result).not_to be_valid
      expect(result.codes).to eq([Kula::Formula::Errors::UNKNOWN_FIELD])
      expect(result.diagnostics.first.position).to eq(16)
    end

    # A half-typed formula is the normal case in an editor, not an exception.
    it "reports a syntax error rather than raising" do
      result = compiler.compile("{Base salary} * (1 +")

      expect(result).not_to be_valid
      expect(result.codes).to include(Kula::Formula::Errors::SYNTAX)
      expect(result.diagnostics.first.position).to be_a(Integer)
    end

    it "reports every bad character at once" do
      result = compiler.compile("1 § 2 ¤ 3")

      expect(result.diagnostics.size).to eq(2)
      expect(result.diagnostics.map(&:position)).to eq([2, 6])
    end

    it "rejects an over-long formula before parsing it" do
      result = described_class.new.compile("1 + " * Kula::Formula::Limits::MAX_LENGTH + "1")

      expect(result.codes).to eq([Kula::Formula::Errors::TOO_LONG])
    end

    it "rejects a formula whose result cannot fit the field" do
      result = compiler.compile("{Job title}", expected_type: :numeric)

      expect(result).not_to be_valid
      expect(result.codes).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
    end

    it "accepts a formula whose result fits" do
      expect(compiler.compile("{Base salary} * 2", expected_type: :numeric)).to be_valid
    end

    # A preview does not know what field it will feed.
    it "skips the type check when no expectation is given" do
      expect(compiler.compile("{Job title}")).to be_valid
    end

    it "accepts the chained conditional form" do
      result = compiler.compile("if({Base salary} > 1, 10) else if({Bonus %} > 1, 20) else(30)")

      expect(result).to be_valid
      expect(result.dependencies).to eq(%w[f_412 f_413])
    end
  end

  describe "#evaluate!" do
    it "computes a compiled formula" do
      stored = compiler.compile("{Base salary} * (1 + {Bonus %} / 100)").stored
      value, error = compiler.evaluate!(stored, "f_412" => 120_000, "f_413" => 10)

      expect(value).to eq(132_000)
      expect(error).to be_nil
    end

    it "reports division by zero rather than raising" do
      value, error = compiler.evaluate!("f_412 / 0", "f_412" => 1)

      expect(value).to be_nil
      expect(error.code).to eq(Kula::Formula::Errors::DIVISION_BY_ZERO)
    end

    # A formula over an unanswered field is "not computable yet", not an error
    # the author has to fix.
    it "reports an unbound reference rather than raising" do
      value, error = compiler.evaluate!("f_412 + 1", {})

      expect(value).to be_nil
      expect(error.code).to eq(Kula::Formula::Errors::NOT_COMPUTABLE)
    end

    # An operation over an unanswered field raises Dentaku::ArgumentError, which
    # descends from ::ArgumentError rather than Dentaku::Error.
    it "reports an operation over a missing value rather than raising" do
      value, error = compiler.evaluate!("f_412 * 2", "f_412" => nil)

      expect(value).to be_nil
      expect(error.code).to eq(Kula::Formula::Errors::NOT_COMPUTABLE)
    end

    it "makes the whole function surface available" do
      value, = compiler.evaluate!(%{upper(trim("  ab  "))})

      expect(value).to eq("AB")
    end
  end
end
