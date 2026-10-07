require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::TypeChecker do
  subject(:checker) { described_class.new(references) }

  let(:ref) { Kula::Formula::Resolver::Reference }
  let(:references) do
    [
      ref.new(handle: "f_num", token: "Salary", kind: :numeric),
      ref.new(handle: "f_str", token: "Title", kind: :string),
      ref.new(handle: "f_unknown", token: "Mystery", kind: nil),
      ref.new(handle: "f_date", token: "Joining date", kind: :date)
    ]
  end

  let(:calculator) { Kula::Formula::Catalog.install(Dentaku::Calculator.new, zone: "UTC") }

  def type_of(source) = checker.result_type(calculator.ast(source))

  # CORE-5505. coalesce/ifnull/max/min answer one of their ARGUMENTS, while the
  # registry has them declaring :numeric. PASS_THROUGH already existed for the
  # first two, but a pass-through fell to inferred_from_children, which answers
  # nil when the children disagree -- and check() lets nil through as "cannot
  # tell". So the same type mix that an if() refuses, because If unifies, was
  # accepted here.
  describe "a pass-through function" do
    def codes(source, expected)
      checker.check(calculator.ast(source), expected: expected).map(&:code)
    end

    {
      "a boolean through coalesce" => %q{coalesce(1 > 0, 5)},
      "a string through coalesce" => %q{coalesce("Y", 5)},
      "a boolean through ifnull" => %q{ifnull(1 > 0, 5)},
      "a date through max" => %q{max(f_date, f_date)},
      "a boolean through min" => %q{min(1 > 0, 0)}
    }.each do |label, source|
      it "refuses #{label} on a number field" do
        expect(codes(source, :numeric)).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
      end
    end

    # The shape that defeated if()'s own check: the coalesce node reported nil,
    # so unify(nil, numeric) answered numeric and the boolean travelled.
    it "refuses a boolean wrapped in coalesce inside an if" do
      expect(codes(%q{if(1 = 1, coalesce(1 > 0, 0), 0)}, :numeric))
        .to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
    end

    # What PASS_THROUGH exists for in the first place, and the reason the
    # declared :numeric cannot simply be trusted.
    it "still accepts a fallback whose type agrees with the field" do
      expect(codes(%q{coalesce(f_str, "n/a")}, :string)).to be_empty
      expect(codes(%q{coalesce(f_num, 0)}, :numeric)).to be_empty
      expect(codes("max(f_num, 1, 2)", :numeric)).to be_empty
      expect(codes(%q{ifnull(f_date, f_date)}, :date)).to be_empty
    end

    # max/min are NOT pass-through: they coerce every argument through as_number
    # and raise on text, so their result really is numeric. Typed as pass-through,
    # max(f_str, f_str) answered :string, a TEXT field accepted it, and it then
    # computed blank on every offer -- refused before that change and after it.
    it "refuses max over text, which it cannot coerce" do
      expect(codes("max(f_str, f_str)", :string)).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
      expect(codes("min(1 > 0, 0)", :numeric)).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
    end

    # An epoch is carried as a number, so the declared :numeric put a date in a
    # number field. All-dates answers :date; a date mixed with a count is the
    # same conflict date arithmetic already is.
    it "answers date only when every operand is one" do
      expect(codes("max(f_date, f_date)", :date)).to be_empty
      expect(codes("max(f_date, f_date)", :numeric)).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
      expect(codes("max(f_date, 1)", :date)).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
      expect(codes("max(f_num, 1, 2)", :numeric)).to be_empty
    end

    # A field of unknown kind is still "cannot tell", not a conflict.
    it "leaves a mix involving an unknown kind alone" do
      expect(codes("coalesce(f_unknown, 5)", :numeric)).to be_empty
    end
  end

  # A date is stored as an integer, but reading it as a number put a salary in a
  # date field as 1970-01-02 and an epoch in a currency field as a billion in
  # money — both with no diagnostic at all.
  describe "dates" do
    it "keeps a date field's own type" do
      expect(type_of("f_date")).to eq(:date)
    end

    it "types the functions that produce a date" do
      expect(type_of("today()")).to eq(:date)
      expect(type_of(%{dateadd(f_date, 90, "day")})).to eq(:date)
    end

    it "types the functions that read a date as numbers" do
      expect(type_of(%{datediff(f_date, today(), "day")})).to eq(:numeric)
      expect(type_of("year(f_date)")).to eq(:numeric)
    end

    it "refuses arithmetic over a date, which reports itself numeric whatever it was given" do
      expect(checker.check(calculator.ast("f_date + 90"), expected: :date).map(&:code))
        .to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
      expect(checker.check(calculator.ast("f_date + f_num"), expected: :numeric).map(&:code))
        .to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
    end

    it "refuses a plain number where a date belongs, and a date where a number belongs" do
      expect(checker.check(calculator.ast("f_num"), expected: :date).map(&:code))
        .to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
      expect(checker.check(calculator.ast("f_date"), expected: :numeric).map(&:code))
        .to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
    end

    it "accepts the date arithmetic that says what unit it means" do
      expect(checker.check(calculator.ast(%{dateadd(f_date, 90, "day")}), expected: :date)).to be_empty
      expect(checker.check(calculator.ast(%{datediff(f_date, today(), "day")}), expected: :numeric)).to be_empty
    end

    it "still compares two dates as a condition" do
      expect(type_of("f_date > today()")).to eq(:logical)
    end
  end

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

    # Distinct from nil: an unknown type is allowed through, so collapsing the two
    # would let a mixed-branch conditional satisfy any expected type.
    it "reports a conflict when a conditional's branches disagree" do
      expect(type_of(%{if(1 > 0, f_num, "x")})).to eq(described_class::CONFLICT)
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

    it "rejects a formula whose branches return different types" do
      result = checker.check(calculator.ast(%{if(1 > 0, f_num, "x")}), expected: :numeric)

      expect(result.map(&:code)).to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
      expect(result.first.detail[:actual]).to eq(:conflicting)
    end

    # A caller asking for a type the language does not model is a caller bug, not
    # a formula the author can fix.
    it "raises on an expected type it does not know" do
      expect { checker.check(calculator.ast("f_num"), expected: :nonsense) }
        .to raise_error(ArgumentError, /nonsense/)
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

  # Dentaku downcases identifiers unless the calculator is built case-sensitive,
  # so an index built from the handle as given missed on any uppercase letter —
  # and a missed lookup reads as "could not determine", which is let through.
  it "still checks a reference whose handle carries an uppercase letter" do
    reference = Kula::Formula::Resolver::Reference.new(handle: "f_A1", token: "Notes", kind: :string)
    compiler = Kula::Formula::Compiler.new(references: [reference])

    expect(compiler.compile("{Notes}", expected_type: :numeric).codes)
      .to eq([Kula::Formula::Errors::RESULT_TYPE_MISMATCH])
  end
end
