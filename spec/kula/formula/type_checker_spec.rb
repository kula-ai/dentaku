require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::TypeChecker do
  subject(:checker) { described_class.new(references) }

  let(:ref) { Kula::Formula::Resolver::Reference }
  let(:references) do
    [
      ref.new(handle: "f_num", token: "Salary", kind: :numeric),
      ref.new(handle: "f_str", token: "Title", kind: :string),
      ref.new(handle: "f_unknown", token: "Mystery", kind: nil)
    ]
  end

  let(:calculator) { Kula::Formula::Catalog.install(Dentaku::Calculator.new, zone: "UTC") }

  def type_of(source) = checker.result_type(calculator.ast(source))

  describe "#result_type" do
    it "reads a literal's own type" do
      expect(type_of("1 + 2")).to eq(:numeric)
      expect(type_of(%{"a"})).to eq(:string)
      expect(type_of("1 > 2")).to eq(:logical)
    end

    # The one thing dentaku cannot work out on its own.
    it "resolves a field reference from the injected references" do
      expect(type_of("f_num")).to eq(:numeric)
      expect(type_of("f_str")).to eq(:string)
    end

    it "propagates through arithmetic over references" do
      expect(type_of("f_num * 2")).to eq(:numeric)
    end

    it "takes the type a conditional's branches agree on" do
      expect(type_of("if(1 > 0, f_num, 0)")).to eq(:numeric)
      expect(type_of(%{if(1 > 0, f_str, "x")})).to eq(:string)
    end

    it "gives no type when a conditional's branches disagree" do
      expect(type_of(%{if(1 > 0, f_num, "x")})).to be_nil
    end

    it "reads a function's declared type" do
      expect(type_of("ceiling(f_num)")).to eq(:numeric)
      expect(type_of(%{upper(f_str)})).to eq(:string)
      expect(type_of(%{equaltext(f_str, "x")})).to eq(:logical)
    end

    # A field whose kind we were told nothing about must not be guessed at.
    it "gives no type for a reference of unknown kind" do
      expect(type_of("f_unknown")).to be_nil
    end
  end

  describe "#check" do
    it "passes when the result fits the field" do
      expect(checker.check(calculator.ast("f_num * 2"), expected: :numeric)).to be_empty
    end

    it "rejects a text result on a numeric field" do
      result = checker.check(calculator.ast(%{upper(f_str)}), expected: :numeric)

      expect(result.map(&:code)).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
      expect(result.first.detail).to eq({expected: :numeric, actual: :string})
    end

    it "rejects a number on a text field" do
      result = checker.check(calculator.ast("f_num + 1"), expected: :string)

      expect(result.map(&:code)).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
    end

    # Rejecting on a guess would block valid formulas, so an indeterminate
    # result passes and fails later at evaluation if it is genuinely wrong.
    it "passes when the result type cannot be determined" do
      expect(checker.check(calculator.ast("f_unknown"), expected: :numeric)).to be_empty
    end

    it "passes when the field has no declared expectation" do
      expect(checker.check(calculator.ast(%{upper(f_str)}), expected: nil)).to be_empty
    end
  end
end
