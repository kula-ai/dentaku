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

    # CORE-5503. advance and difference are a case over the unit with no else, so
    # an unrecognised one answered nil and authoring called the formula valid --
    # the field then computed blank on every offer with nothing said anywhere.
    describe "a dateadd/datediff unit" do
      {
        "a typo" => %q{dateadd(today(), 1, "monts")},
        "a unit the readers do not offer" => %q{dateadd(today(), 1, "decades")},
        "an empty one" => %q{dateadd(today(), 1, "")},
        "one on datediff" => %q{datediff(today(), today(), "nonsense")}
      }.each do |label, source|
        it "refuses #{label}" do
          result = compiler.compile(source)

          expect(result.codes).to eq([Kula::Formula::Errors::INVALID_UNIT])
        end
      end

      it "says which unit and what was expected, so the editor can name both" do
        detail = compiler.compile(%q{dateadd(today(), 1, "monts")}).diagnostics.first.detail

        expect(detail).to eq(function: "dateadd", unit: "monts",
          expects: Kula::Formula::Catalog::DATE_UNITS)
      end

      it "accepts every unit the readers handle, in either case" do
        Kula::Formula::Catalog::DATE_UNITS.each do |unit|
          expect(compiler.compile(%{dateadd(today(), 1, "#{unit}")}).codes).to be_empty
          expect(compiler.compile(%{dateadd(today(), 1, "#{unit.upcase}")}).codes).to be_empty
        end
      end

      # A unit arriving from a field cannot be known while the admin is typing,
      # and guessing would refuse a formula that works.
      it "leaves a unit it cannot see alone" do
        expect(compiler.compile("dateadd(today(), 1, s_title)").codes).to be_empty
      end

      # ...and because authoring cannot see it, EVALUATION has to name it. It used
      # to answer nil, which the host reads as "waiting on an input", so a formula
      # that can never compute sent the recruiter to fill in a field. The same
      # code the compiler gives a bad literal, so the two agree about one mistake.
      it "names the same code at evaluation for a unit that came from a field" do
        result = compiler.compile("dateadd(today(), 1, s_title)")
        value, diagnostic = compiler.evaluate!(result.stored, {"s_title" => "monts"})

        expect(value).to be_nil
        expect(diagnostic.code).to eq(Kula::Formula::Errors::INVALID_UNIT)
        expect(diagnostic.detail)
          .to eq(function: "dateadd", unit: "monts", expects: Kula::Formula::Catalog::DATE_UNITS)
      end
    end

    # CORE-5503, widened. The readers raise Dentaku::ArgumentError on a literal
    # they cannot read as a number, which evaluate reports as NOT_COMPUTABLE --
    # and the host renders that as "waiting on an input". So a recruiter was sent
    # to fill in a field because an admin had typed "five" where a count goes.
    describe "a literal where a number is wanted" do
      {
        "dateadd's count" => [%q{dateadd(today(), "five", "days")}, "dateadd", 2, "five"],
        "dateadd's timestamp" => [%q{dateadd("notadate", 1, "days")}, "dateadd", 1, "notadate"],
        "round's places" => [%q{round(1.5, "x")}, "round", 2, "x"],
        "abs's operand" => [%q{abs("x")}, "abs", 1, "x"]
      }.each do |label, (source, function, argument, value)|
        it "refuses #{label}, naming the argument" do
          result = compiler.compile(source)

          expect(result.codes).to eq([Kula::Formula::Errors::ARGUMENT_TYPE])
          expect(result.diagnostics.first.detail)
            .to eq(function: function, argument: argument, value: value)
        end
      end

      # The variadic aggregates take numbers in every position. On a NUMBER field
      # the result-type check happened to catch these; on a text field nothing did.
      it "refuses a non-numeric operand to max or min in any position" do
        expect(compiler.compile(%q{max("a", 1)}).codes).to eq([Kula::Formula::Errors::ARGUMENT_TYPE])
        expect(compiler.compile(%q{min(1, "b")}).codes).to eq([Kula::Formula::Errors::ARGUMENT_TYPE])
      end

      # A numeric string coerces on purpose, and the readers compute the right
      # answer from it -- refusing it would break a formula that works.
      it "accepts a numeric string, which the readers coerce" do
        expect(compiler.compile(%q{dateadd(today(), "7", "days")}).codes).to be_empty
        expect(compiler.compile(%q{round("1.5", 2)}).codes).to be_empty
      end

      # A field's value cannot be known while the admin is typing, so guessing
      # would refuse a formula that works.
      it "leaves a field reference alone" do
        expect(compiler.compile("dateadd(today(), {Base salary}, \"days\")").codes).to be_empty
      end

      # date's one-argument form parses TEXT, which is why it is not on the list.
      it "does not touch a function whose argument is meant to be text" do
        expect(compiler.compile(%q{date("2026-04-25")}).codes).to be_empty
        expect(compiler.compile(%q{concat("a", "b")}).codes).to be_empty
      end
    end

    # CORE-5503. Registered upstream as ->(*args), so the parser's arity check
    # passed an empty call where concat() and abs(-5, 3) are both refused.
    describe "max/min arity" do
      it "refuses a call with no arguments, under the code a wrong count already has" do
        expect(compiler.compile("max()").codes).to eq([Kula::Formula::Errors::SYNTAX])
        expect(compiler.compile("min()").codes).to eq([Kula::Formula::Errors::SYNTAX])
      end

      it "accepts one argument or many" do
        expect(compiler.compile("max(1)").codes).to be_empty
        expect(compiler.compile("max(1, 2, 3)").codes).to be_empty
        expect(compiler.compile("min(4, 5)").codes).to be_empty
      end
    end

    # CORE-5504. if() answered its THEN branch for ANY non-boolean condition, 0
    # and "" included, so `if({salary}, "haspay", "nopay")` wrote "haspay" on a
    # zero salary. and/or already decline a non-boolean.
    describe "an if() condition" do
      {
        "a number" => %q{if(5, "T", "E")},
        "zero" => %q{if(0, "T", "E")},
        "an empty string" => %q{if("", "T", "E")},
        "a numeric field" => %q{if({Base salary}, "T", "E")}
      }.each do |label, source|
        it "refuses #{label}" do
          result = compiler.compile(source)

          expect(result.codes).to include(Kula::Formula::Errors::CONDITION_NOT_LOGICAL)
        end
      end

      it "names the construct and the type it was given" do
        detail = compiler.compile(%q{if(5, "T", "E")}).diagnostics.first.detail

        expect(detail).to eq(function: "if", actual: :numeric)
      end

      it "accepts a real comparison" do
        expect(compiler.compile(%q{if(1 = 2, "T", "E")}).codes).to be_empty
        expect(compiler.compile(%q{if({Base salary} > 0, "T", "E")}).codes).to be_empty
      end
    end

    # CORE-5504, the other half. not() read a non-boolean as TRUE the same way,
    # so not(0) answered false where correct truthiness would answer true --
    # a wrong value in a Yes/No field rather than a blank, and nothing said.
    describe "a not() operand" do
      {
        "a number" => "not(5)",
        "zero" => "not(0)",
        "a string" => %q{not("x")},
        "a numeric field" => "not({Base salary})"
      }.each do |label, source|
        it "refuses #{label}" do
          expect(compiler.compile(source).codes)
            .to include(Kula::Formula::Errors::CONDITION_NOT_LOGICAL)
        end
      end

      it "names not() as the construct" do
        detail = compiler.compile("not(5)").diagnostics.first.detail

        expect(detail).to eq(function: "not", actual: :numeric)
      end

      it "accepts a real comparison" do
        expect(compiler.compile("not(1 = 2)").codes).to be_empty
        expect(compiler.compile("not({Base salary} > 0)").codes).to be_empty
      end
    end

    # A conflicting condition is reported NOWHERE else: check() looks at the root
    # only, and the root of an if/not is typed from its branches or declared
    # :logical. Skipped as "never reject on a guess" it computed the wrong value
    # 5504 exists to stop -- not(coalesce(0, 1 > 0)) answered false.
    describe "a condition whose children disagree" do
      it "refuses it through not() and if()" do
        expect(compiler.compile("not(coalesce(0, 1 > 0))").codes)
          .to include(Kula::Formula::Errors::CONDITION_NOT_LOGICAL)
        expect(compiler.compile("if(coalesce(0, 1 > 0), 1, 2)").codes)
          .to include(Kula::Formula::Errors::CONDITION_NOT_LOGICAL)
      end

      it "names the conflict the way check() does" do
        detail = compiler.compile("not(coalesce(0, 1 > 0))").diagnostics.first.detail

        expect(detail).to eq(function: "not", actual: :conflicting)
      end
    end

    # and/or already answer NOT_COMPUTABLE at runtime, which is a blank the
    # recruiter is told about rather than a wrong number. Left as they are, so
    # this pins that the check did not widen to them and tighten saved formulas.
    it "leaves a non-boolean and/or operand to the runtime" do
      expect(compiler.compile("and(5, 1 > 0)").codes).to be_empty
      expect(compiler.compile("or(0, 1 > 0)").codes).to be_empty
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

    # A single long literal rather than a chain: a chain that long is over the
    # operation cap too, and this example is about the length one.
    it "rejects an over-long formula before parsing it" do
      result = described_class.new.compile("1" * (Kula::Formula::Limits::MAX_LENGTH + 1))

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

    # nil is a legitimate answer, not a failure. The two-arg if is the fork's own
    # grammar feature and the harness asserts it returns nil.
    it "reports a conditional that did not match as an answer, not a failure" do
      value, error = compiler.evaluate!("if(1>2, 10)")

      expect(value).to be_nil
      expect(error).to be_nil
    end

    # to_i ran before to_date saw the value, so "abc" became 0 and read as 1970 —
    # the same bug this closed for year/month/day.
    it "does not read a wrong-typed datediff operand as the epoch" do
      value, error = compiler.evaluate!(%{datediff(f_412, 0, "day")}, "f_412" => "abc")

      expect(value).to be_nil
      expect(error.code).to eq(Kula::Formula::Errors::NOT_COMPUTABLE)
    end

    it "does not read a wrong-typed dateadd amount as zero" do
      value, error = compiler.evaluate!(%{dateadd(0, f_412, "day")}, "f_412" => "abc")

      expect(value).to be_nil
      expect(error.code).to eq(Kula::Formula::Errors::NOT_COMPUTABLE)
    end

    # Float would accept "0x10" and cap precision at ~15 digits; dentaku carries
    # decimals as BigDecimal.
    it "keeps a large decimal exact rather than routing it through Float" do
      value, = compiler.evaluate!("ceiling(f_412)", "f_412" => BigDecimal("9007199254740993.2"))

      expect(value).to eq(9_007_199_254_740_994)
    end

    it "does not accept hex notation as a number" do
      value, error = compiler.evaluate!("ceiling(f_412)", "f_412" => "0x10")

      expect(value).to be_nil
      expect(error.code).to eq(Kula::Formula::Errors::NOT_COMPUTABLE)
    end

    # add_function declares a return type, not argument types, so a wrong-typed
    # operand reaches the lambda. It used to raise NoMethodError straight past
    # this method to the host.
    it "reports a wrong-typed operand rather than raising" do
      value, error = compiler.evaluate!("ceiling(f_412)", "f_412" => "abc")

      expect(value).to be_nil
      expect(error.code).to eq(Kula::Formula::Errors::NOT_COMPUTABLE)
    end

    # to_i on a non-number is 0, which reads back as 1970 — plausible-looking
    # wrong data with no diagnostic at all.
    it "does not read a wrong-typed operand as the epoch" do
      value, error = compiler.evaluate!("year(f_412)", "f_412" => "abc")

      expect(value).to be_nil
      expect(error.code).to eq(Kula::Formula::Errors::NOT_COMPUTABLE)
    end
  end

  describe "what the surface admits" do
    # Installing onto a stock calculator leaves every dentaku built-in reachable.
    # This is the whitelist, so it needs pinning.
    it "rejects a dentaku built-in outside the catalog" do
      expect(compiler.compile(%{left("abcdef", 3)}).codes)
        .to eq([Kula::Formula::Errors::UNKNOWN_FUNCTION])
    end

    # A *args lambda has arity -1, so the parser checked nothing: date(2026, 4)
    # compiled clean, saved green, and raised at call time -- reaching the
    # recruiter as a field that would not compute rather than the author as a
    # formula to fix. round(1, 2, 3) was refused all along, being fixed-arity.
    it "rejects a variadic function given a count it does not take" do
      expect(compiler.compile("date(2026, 4)").codes).to eq([Kula::Formula::Errors::SYNTAX])
      expect(compiler.compile("date(2026, 4, 25, 1)").codes).to eq([Kula::Formula::Errors::SYNTAX])
      expect(compiler.compile("days_between(1, 2, 3)").codes).to eq([Kula::Formula::Errors::SYNTAX])
    end

    it "names the function and what it takes" do
      detail = compiler.compile("date(2026, 4)").diagnostics.first.detail

      expect(detail).to eq({function: "date", given: 2, expects: [1, 3]})
    end

    it "accepts every count a variadic function does take" do
      expect(compiler.compile(%{date("2026-04-25")})).to be_valid
      expect(compiler.compile("date(2026, 4, 25)")).to be_valid
      expect(compiler.compile("days_between(1)")).to be_valid
      expect(compiler.compile("days_between(1, 2)")).to be_valid
    end

    # concat, min, max and coalesce mean whatever number they are given, so they
    # are absent from the table and must stay unrestricted.
    it "leaves a genuinely variadic function alone" do
      expect(compiler.compile(%{concat("a", "b", "c", "d")})).to be_valid
      expect(compiler.compile("coalesce(1, 2, 3, 4)")).to be_valid
      expect(compiler.compile("min(1, 2, 3)")).to be_valid
    end

    # CASE is not an AST::Function, so the whitelist never saw it, and its
    # branches were invisible to both the whitelist and the type checker.
    it "rejects CASE, which is not on the surface" do
      expect(compiler.compile(%{CASE 1 WHEN 1 THEN 2 ELSE 3 END}).codes)
        .to eq([Kula::Formula::Errors::UNSUPPORTED_CONSTRUCT])
    end

    # not_to be_valid would pass on the CASE rejection alone, saying nothing about
    # whether the walk ever reached the branch.
    it "does not let CASE smuggle an excluded function past the whitelist" do
      expect(compiler.compile(%{CASE 1 WHEN 1 THEN left("abc", 1) ELSE 0 END}).codes)
        .to include(Kula::Formula::Errors::UNKNOWN_FUNCTION)
    end

    # Nine characters that pass every budget and then ask Ruby for a number with
    # hundreds of millions of digits. Limits bounds the source, not the result.
    it "rejects exponentiation, which no budget can bound" do
      expect(compiler.compile("9^9^9^9").codes)
        .to eq([Kula::Formula::Errors::UNSUPPORTED_CONSTRUCT])
    end

    it "rejects the bitwise shifts, which are not on the surface either" do
      expect(compiler.compile("1 << 8").codes)
        .to eq([Kula::Formula::Errors::UNSUPPORTED_CONSTRUCT])
    end

    it "still admits ordinary arithmetic" do
      expect(compiler.compile("(f_412 + 1) * 3")).to be_valid
    end

    it "rejects a handle typed directly for a field that does not exist" do
      expect(compiler.compile("f_999 + 1").codes)
        .to eq([Kula::Formula::Errors::DANGLING_REFERENCE])
    end

    # CORE-5491. `%` is two operators -- infix modulo and postfix percentage --
    # so `10 % -3` is one token stream with two readings: "10 modulo -3" is -2
    # and "10 percent, minus 3" is -2.9. Refusing it is right; choosing a reading
    # made `100000 * 10% - 500` answer 0.0 in kula.17 and was reverted. Its own
    # code only because err_formula_syntax named nothing an author could act on.
    describe "a percentage next to a sign" do
      {
        "a bare negative divisor" => "10 % -3",
        "it unspaced" => "10 %-3",
        "it spaced apart" => "10 % - 3",
        "the stream read as a percentage" => "50% - 3",
        "the shape an author actually writes" => "100000 * 10% - 500",
        "one nested inside addition" => "1 + 50% - 3"
      }.each do |label, source|
        it "names the ambiguity for #{label}" do
          result = compiler.compile(source)

          expect(result.codes).to eq([Kula::Formula::Errors::PERCENT_AMBIGUOUS])
        end
      end

      it "says which operator, and both readings" do
        diagnostic = compiler.compile("10 % -3").diagnostics.first

        expect(diagnostic.detail).to eq(operator: "%", readings: %w[modulo percent])
        expect(diagnostic.position).to eq(6)
      end

      # The parser blames whatever ENCLOSES the collision -- Multiplication for
      # the realistic shape, Percentage only for a bare two-term one -- so the
      # check is on the tokens. These pin that it did not widen into a source
      # scan: each contains a percentage, and each keeps the code it had.
      it "leaves an unambiguous percentage alone" do
        expect(compiler.compile("10 % (-3)").codes).to be_empty
        expect(compiler.compile("(50%) - 3").codes).to be_empty
        expect(compiler.compile("10 % 3").codes).to be_empty
        expect(compiler.compile("-10 % 3").codes).to be_empty
        expect(compiler.compile("2 * 50%").codes).to be_empty
      end

      # A real syntax error in a formula that merely CONTAINS a percentage: the
      # mod and the negate are not adjacent, so it keeps the generic code.
      it "does not claim the ambiguity for an unrelated syntax error" do
        expect(compiler.compile("10 % 3 + * 2").codes).to eq([Kula::Formula::Errors::SYNTAX])
        expect(compiler.compile("10 + * 3").codes).to eq([Kula::Formula::Errors::SYNTAX])
      end
    end

    # Not handle-shaped, so the old source scan never saw it.
    it "rejects a bare field name someone typed without braces" do
      expect(compiler.compile("revenue * 2").codes)
        .to eq([Kula::Formula::Errors::DANGLING_REFERENCE])
    end

    # CORE-5532. A date is an epoch integer at evaluation and the language has no
    # separate date value, so the coercion point cannot tell today() from a
    # number: concat("Start: ", today()) wrote the epoch into the offer letter.
    # The type checker knows while compiling, which is the only place to say so.
    describe "a date handed to a text function" do
      {
        "concat" => %q{concat("Start: ", today())},
        "len" => "len(today())",
        "upper" => "upper(f_joining)",
        "contains" => %q{contains("x", today())},
        "equaltext" => %q{equaltext(today(), "x")},
        "a date FIELD, whose kind is known" => %q{concat("Start: ", f_joining)}
      }.each do |label, source|
        it "refuses it through #{label}" do
          expect(dated.compile(source).codes)
            .to include(Kula::Formula::Errors::DATE_NEEDS_FORMAT)
        end
      end

      it "names the function and the remedy" do
        detail = dated.compile(%q{concat("Start: ", today())}).diagnostics.first.detail

        expect(detail).to eq(function: "concat", argument: 2, expects: "format_date")
      end

      # format_date is the remedy, so refusing a date there would refuse the fix.
      it "accepts the date once it is formatted" do
        expect(dated.compile(%q{concat("Start: ", format_date(today(), "DD/MM/YYYY"))}).codes)
          .to be_empty
      end

      it "leaves a number, an unknown kind and date arithmetic alone" do
        expect(dated.compile(%q{concat("Pay: ", f_412)}).codes).to be_empty
        expect(dated.compile(%q{concat("X: ", f_mystery)}).codes).to be_empty
        expect(dated.compile(%q{datediff(today(), f_joining, "days")}, expected_type: :numeric).codes)
          .to be_empty
      end

      let(:dated) do
        described_class.new(zone: "UTC", references: references + [
          ref.new(handle: "f_joining", token: "Joining", kind: :date),
          ref.new(handle: "f_mystery", token: "Mystery", kind: nil)
        ])
      end
    end
  end

  # CORE-5532. humanize wrote a BigDecimal's full decimal because the gem had no
  # display scale, so a non-terminating division rendered ~33 places in text
  # where the host shows 4 -- and len/contains answered on the long form, which
  # is a wrong number and a wrong boolean rather than a cosmetic one.
  describe "the display scale" do
    subject(:scaled) { described_class.new(references: references, zone: "UTC", scale: 4) }

    def value(source, compiler = scaled)
      compiler.evaluate!(compiler.compile(source).stored).first
    end

    it "rounds a non-terminating division in every text function" do
      expect(value(%q{concat("", 100000/3)})).to eq("33333.3333")
      expect(value("len(100000/3)")).to eq(10)
      expect(value("upper(100000/3)")).to eq("33333.3333")
      expect(value("left(100000/3, 5)")).to eq("33333")
    end

    # The two that answered a wrong VALUE, not just a long string.
    it "stops contains and equaltext matching digits no reader can see" do
      expect(value(%q{contains("333333333333", 100000/3)})).to be(false)
      expect(value(%q{contains("3333", 100000/3)})).to be(true)
      expect(value(%q{equaltext(100000/3, "33333.3333")})).to be(true)
    end

    it "leaves everything that already rendered correctly" do
      expect(value("len(100/4)")).to eq(2)
      expect(value(%q{concat("", 5.50)})).to eq("5.5")
      expect(value(%q{concat("", 5.05)})).to eq("5.05")
      expect(value(%q{concat("", 1 > 0)})).to eq("true")
      expect(value(%q{concat("", round(100000/3, 2))})).to eq("33333.33")
      expect(value(%q{lower("ABC")})).to eq("abc")
      expect(value(%q{trim("  x  ")})).to eq("x")
    end

    # A host that states no scale keeps what it had, so the gem does not impose a
    # display rule of its own.
    it "keeps full precision when no scale is given" do
      expect(value(%q{concat("", 100000/3)}, compiler).length).to be > 20
    end
  end
end
