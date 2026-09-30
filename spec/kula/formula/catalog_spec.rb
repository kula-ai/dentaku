require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::Catalog do
  subject(:calculator) { described_class.install(Dentaku::Calculator.new, zone: zone) }

  let(:zone) { "UTC" }
  let(:timestamp) { Time.utc(2026, 1, 15, 14, 30).to_i }

  describe "numeric" do
    it "adds ceiling and floor" do
      expect(calculator.evaluate!("ceiling(1.2)")).to eq(2)
      expect(calculator.evaluate!("floor(1.8)")).to eq(1)
    end
  end

  describe "dates" do
    it "extracts the parts of a timestamp" do
      expect(calculator.evaluate!("year(#{timestamp})")).to eq(2026)
      expect(calculator.evaluate!("month(#{timestamp})")).to eq(1)
      expect(calculator.evaluate!("day(#{timestamp})")).to eq(15)
    end

    # The reason the zone is a parameter at all: reading the same integer as UTC
    # when the host displays a local zone puts year() and day() on a different
    # day from the value shown for that very field.
    context "with ActiveSupport loaded" do
      before do
        require "active_support/core_ext/time/zones"
        require "active_support/core_ext/date/zones"
      rescue ::LoadError
        skip "ActiveSupport is not available"
      end

      it "reads a timestamp in the supplied zone, not UTC" do
        stamp = Time.utc(2026, 1, 14, 20, 0).to_i

        in_kolkata = described_class.install(Dentaku::Calculator.new, zone: "Asia/Kolkata")
        in_utc = described_class.install(Dentaku::Calculator.new, zone: "UTC")

        expect(in_kolkata.evaluate!("day(#{stamp})")).to eq(15)
        expect(in_utc.evaluate!("day(#{stamp})")).to eq(14)
      end
    end

    # Without it the zone argument has no effect and everything reads as UTC.
    # Deterministic, but the contract has to be stated rather than assumed.
    it "falls back to UTC when ActiveSupport is absent" do
      skip "ActiveSupport is loaded in this process" if Time.now.respond_to?(:in_time_zone)

      stamp = Time.utc(2026, 1, 14, 20, 0).to_i
      expect(described_class.install(Dentaku::Calculator.new, zone: "Asia/Kolkata").evaluate!("day(#{stamp})")).to eq(14)
    end

    it "advances by each supported unit" do
      expect(calculator.evaluate!(%{day(dateadd(#{timestamp}, 3, "days"))})).to eq(18)
      expect(calculator.evaluate!(%{day(dateadd(#{timestamp}, 1, "weeks"))})).to eq(22)
      expect(calculator.evaluate!(%{month(dateadd(#{timestamp}, 2, "months"))})).to eq(3)
      expect(calculator.evaluate!(%{year(dateadd(#{timestamp}, 1, "years"))})).to eq(2027)
    end

    # A typo'd unit is the expected failure mode for an author-typed literal, so
    # it must surface rather than quietly meaning days.
    it "yields nil for a unit it does not recognise" do
      expect(calculator.evaluate!(%{dateadd(#{timestamp}, 3, "moth")})).to be_nil
      expect(calculator.evaluate!(%{datediff(#{timestamp}, #{timestamp}, "moth")})).to be_nil
    end

    it "is date-granular, dropping time of day" do
      midnight = Time.utc(2026, 1, 15).to_i

      expect(calculator.evaluate!(%{dateadd(#{timestamp}, 0, "days")})).to eq(midnight)
    end

    describe "datediff" do
      let(:later) { Time.utc(2026, 1, 2, 0, 30).to_i }
      let(:earlier) { Time.utc(2026, 1, 1, 23, 30).to_i }

      # Measured between dates, not raw seconds: an hour apart across midnight is
      # a day apart, and day() already says so.
      it "agrees with day() across a midnight boundary" do
        expect(calculator.evaluate!(%{datediff(#{later}, #{earlier}, "days")})).to eq(1)
        expect(calculator.evaluate!("day(#{later})")).to eq(2)
        expect(calculator.evaluate!("day(#{earlier})")).to eq(1)
      end

      # Integer division on seconds floors toward -infinity, which made these
      # disagree for any sub-day gap.
      # Integer division floors toward -infinity and the month adjustment always
      # rounds toward the past, so every unit had to be checked, not just days.
      it "is symmetric in every unit" do
        a = Time.utc(2026, 3, 15).to_i
        b = Time.utc(2026, 1, 10).to_i

        %w[days weeks months years].each do |unit|
          forward = calculator.evaluate!(%{datediff(#{a}, #{b}, "#{unit}")})
          backward = calculator.evaluate!(%{datediff(#{b}, #{a}, "#{unit}")})

          expect(forward).to eq(-backward), "#{unit}: #{forward} vs #{backward}"
        end
      end

      it "measures weeks, months and years" do
        march = Time.utc(2026, 3, 15).to_i
        jan = Time.utc(2026, 1, 15).to_i

        expect(calculator.evaluate!(%{datediff(#{march}, #{jan}, "months")})).to eq(2)
        expect(calculator.evaluate!(%{datediff(#{march}, #{jan}, "weeks")})).to eq(8)
      end
    end

    it "returns today in the supplied zone" do
      expect(calculator.evaluate!("year(today())")).to eq(Time.now.utc.year)
    end

    # Without a constructor, "the end of this year" can only be written as a
    # literal date, which is right until the year turns and silently wrong after.
    describe "date()" do
      it "builds a timestamp from its parts" do
        expect(calculator.evaluate!("year(date(2027, 3, 1))")).to eq(2027)
        expect(calculator.evaluate!("month(date(2027, 3, 1))")).to eq(3)
        expect(calculator.evaluate!("day(date(2027, 3, 1))")).to eq(1)
      end

      it "composes with the rest of the date functions" do
        expect(calculator.evaluate!(%{datediff(date(year(#{timestamp}) + 1, 1, 1), #{timestamp}, "days")})).to eq(351)
      end

      # The parts can be fields, and an unanswered field arrives as nil.
      it "is not computable when a part is unanswered" do
        expect(calculator.evaluate!("date(2027, 3, day_of)", "day_of" => nil)).to be_nil
      end

      it "is not computable for a day that does not exist" do
        expect(calculator.evaluate!("date(2027, 2, 31)")).to be_nil
      end

      # An author types a date the way they read one. Every shape below has a
      # single reading, so accepting them costs nothing and refusing them would
      # only teach the author our preferences.
      describe "from text" do
        it "reads every unambiguous shape as the same day" do
          expected = calculator.evaluate!("date(2026, 4, 25)")

          [
            "2026-04-25",
            "25/04/2026",
            "25-04-2026",
            "25 Apr 2026",
            "Apr 25, 2026",
            "25 April 2026"
          ].each do |written|
            expect(calculator.evaluate!(%{date("#{written}")})).to eq(expected), written
          end
        end

        # The one shape with two readings: 01/04/2026 is 1 April to most of the
        # world and 4 January to the United States. Guessing puts a plausible
        # wrong date into a document nobody re-reads.
        it "refuses a numeric date that could be read either way" do
          expect(calculator.evaluate!(%{date("01/04/2026")})).to be_nil
          expect(calculator.evaluate!(%{date("04-01-2026")})).to be_nil
        end

        # Same separators, but 25 cannot be a month, so there is nothing to guess.
        it "accepts the same shape once one number can only be a day" do
          expect(calculator.evaluate!(%{date("25/04/2026")})).to eq(calculator.evaluate!("date(2026, 4, 25)"))
        end

        it "is not computable for text that is not a date" do
          expect(calculator.evaluate!(%{date("not a date")})).to be_nil
          expect(calculator.evaluate!(%{date("")})).to be_nil
        end
      end

      # How an author answers the question date() refuses to guess.
      describe "parsedate()" do
        it "reads a date in the format the author states" do
          expect(calculator.evaluate!(%{parsedate("01/04/2026", "dd/MM/yyyy")}))
            .to eq(calculator.evaluate!("date(2026, 4, 1)"))
          expect(calculator.evaluate!(%{parsedate("01/04/2026", "MM/dd/yyyy")}))
            .to eq(calculator.evaluate!("date(2026, 1, 4)"))
        end

        it "reads the month by name" do
          expect(calculator.evaluate!(%{parsedate("April 1 2026", "MMMM d yyyy")}))
            .to eq(calculator.evaluate!("date(2026, 4, 1)"))
        end

        it "is not computable when the text does not match the format" do
          expect(calculator.evaluate!(%{parsedate("2026-04-01", "dd/MM/yyyy")})).to be_nil
        end
      end
    end
  end

  # The functions a compensation formula actually reaches for. Zoho Analytics,
  # which product reads these against, ships about eighty; these are the ones an
  # offer is written with.
  describe "the rest of the date surface" do
    let(:mid_march) { Time.utc(2026, 3, 18).to_i }   # a Wednesday

    it "reads the quarter, the weekday and the day's name" do
      expect(calculator.evaluate!("quarter(#{mid_march})")).to eq(1)
      expect(calculator.evaluate!("weekday(#{mid_march})")).to eq(3)
      expect(calculator.evaluate!("dayname(#{mid_march})")).to eq("Wednesday")
    end

    # 1 is Monday, so "not a weekend" is weekday(d) < 6 everywhere.
    it "numbers the weekend last" do
      saturday = Time.utc(2026, 3, 21).to_i

      expect(calculator.evaluate!("weekday(#{saturday})")).to eq(6)
    end

    describe "boundaries" do
      it "finds the start and end of a month, quarter and year" do
        expect(calculator.evaluate!(%{day(start_day("month", #{mid_march}))})).to eq(1)
        expect(calculator.evaluate!(%{day(end_day("month", #{mid_march}))})).to eq(31)
        expect(calculator.evaluate!(%{month(start_day("quarter", #{mid_march}))})).to eq(1)
        expect(calculator.evaluate!(%{month(end_day("quarter", #{mid_march}))})).to eq(3)
        expect(calculator.evaluate!(%{month(start_day("year", #{mid_march}))})).to eq(1)
        expect(calculator.evaluate!(%{day(end_day("year", #{mid_march}))})).to eq(31)
      end

      it "finds the Monday and Sunday of a week" do
        expect(calculator.evaluate!(%{dayname(start_day("week", #{mid_march}))})).to eq("Monday")
        expect(calculator.evaluate!(%{dayname(end_day("week", #{mid_march}))})).to eq("Sunday")
      end

      it "reads February in a leap year" do
        feb = Time.utc(2028, 2, 10).to_i

        expect(calculator.evaluate!("day(lastday(#{feb}))")).to eq(29)
      end

      # Same reasoning as dateadd: a typo'd unit must surface rather than mean
      # something plausible.
      it "yields nil for a unit it does not recognise" do
        expect(calculator.evaluate!(%{start_day("fortnight", #{mid_march})})).to be_nil
      end
    end

    describe "spans" do
      let(:from) { Time.utc(2026, 1, 10).to_i }
      let(:to) { Time.utc(2026, 3, 15).to_i }

      # from, to — the order the question is asked in, and the reverse of
      # datediff's later/earlier.
      it "counts days, months and years from one date to another" do
        expect(calculator.evaluate!("days_between(#{from}, #{to})")).to eq(64)
        expect(calculator.evaluate!("months_between(#{from}, #{to})")).to eq(2)
        expect(calculator.evaluate!("age_years(#{Time.utc(2000, 1, 10).to_i}, #{to})")).to eq(26)
      end

      # Which is what a tenure or a notice period is measured against.
      it "measures to today when the far end is left out" do
        expect(calculator.evaluate!("days_between(today())")).to eq(0)
      end

      # A notice period is counted in working days far more often than calendar
      # ones. Mon 16th to Mon 23rd is five.
      it "counts business days, excluding weekends" do
        monday = Time.utc(2026, 3, 16).to_i
        next_monday = Time.utc(2026, 3, 23).to_i

        expect(calculator.evaluate!("business_days(#{monday}, #{next_monday})")).to eq(5)
      end

      it "counts business days backwards as a negative" do
        monday = Time.utc(2026, 3, 16).to_i
        next_monday = Time.utc(2026, 3, 23).to_i

        expect(calculator.evaluate!("business_days(#{next_monday}, #{monday})")).to eq(-5)
      end
    end

    # A date inside a text field or an offer letter, in the same tokens parsedate
    # reads.
    it "formats a date as text" do
      expect(calculator.evaluate!(%{format_date(#{mid_march}, "dd/MM/yyyy")})).to eq("18/03/2026")
      expect(calculator.evaluate!(%{format_date(#{mid_march}, "d MMM yyyy")})).to eq("18 Mar 2026")
    end

    it "keeps the time of day, which every other date function drops" do
      expect(calculator.evaluate!("now()")).to be_within(5).of(Time.now.to_i)
    end
  end

  describe "text" do
    it "adds case functions and trim" do
      expect(calculator.evaluate!(%{upper("ab")})).to eq("AB")
      expect(calculator.evaluate!(%{lower("AB")})).to eq("ab")
      expect(calculator.evaluate!(%{trim("  a  ")})).to eq("a")
    end

    it "compares text case-insensitively" do
      expect(calculator.evaluate!(%{equaltext("Contractor", "contractor")})).to be true
      expect(calculator.evaluate!(%{equaltext("Contractor", "Permanent")})).to be false
    end

    # Argument order matches upstream — needle first — so a formula written
    # against dentaku's documented signature keeps its meaning.
    it "keeps upstream's needle-first argument order for contains" do
      stock = Dentaku::Calculator.new

      expect(calculator.evaluate!(%{contains("Eng", "Senior Engineer")})).to be true
      expect(stock.evaluate!(%{contains("Eng", "Senior Engineer")})).to be true
    end

    it "makes contains case-insensitive, unlike upstream" do
      expect(calculator.evaluate!(%{contains("eng", "Senior Engineer")})).to be true
      expect(Dentaku::Calculator.new.evaluate!(%{contains("eng", "Senior Engineer")})).to be false
    end
  end

  describe "nulls" do
    it "provides coalesce, ifnull and isnull" do
      expect(calculator.evaluate!("coalesce(null, 5)")).to eq(5)
      expect(calculator.evaluate!("ifnull(null, 5)")).to eq(5)
      expect(calculator.evaluate!("ifnull(2, 5)")).to eq(2)
      expect(calculator.evaluate!("isnull(null)")).to be true
    end
  end

  # An unanswered field is nil, and nil is not an empty string: two blank fields
  # must not compare equal, or a gate built on equaltext fires on data nobody
  # has filled in.
  describe "nil tolerance" do
    it "propagates nil through every registered function" do
      {
        "ceiling(null)" => nil, "floor(null)" => nil,
        "upper(null)" => nil, "lower(null)" => nil, "trim(null)" => nil,
        "year(null)" => nil, "month(null)" => nil, "day(null)" => nil,
        %{dateadd(null, 1, "days")} => nil, %{datediff(null, null, "days")} => nil,
        "equaltext(null, null)" => nil, "contains(null, null)" => nil
      }.each do |source, expected|
        expect(calculator.evaluate!(source)).to eq(expected), "#{source} should be #{expected.inspect}"
      end
    end

    it "does not treat two unanswered fields as equal" do
      expect(calculator.evaluate!("equaltext(a, b)", "a" => nil, "b" => nil)).to be_nil
    end
  end

  # Dentaku parses the infix forms as operators but the call forms as functions;
  # rejecting not(x) while accepting `a and b` would be an arbitrary split.
  describe "the logical surface" do
    it "accepts and, or and not in call form" do
      expect(calculator.evaluate!("not(1 > 2)")).to be true
      expect(calculator.evaluate!("and(1 > 0, 2 > 1)")).to be true
      expect(calculator.evaluate!("or(1 > 2, 2 > 1)")).to be true
    end
  end

  # The host parses a typed date too: a field's DEFAULT value is authored in the
  # drawer rather than in a formula, and which shapes are accepted has to be one
  # rule rather than two that drift.
  describe ".parse_date" do
    it "is public, because the host reads it" do
      expect(described_class).to respond_to(:parse_date)
    end

    it "reads every unambiguous shape" do
      expect(described_class.parse_date("2026-04-25")).to eq(Date.new(2026, 4, 25))
      expect(described_class.parse_date("25/04/2026")).to eq(Date.new(2026, 4, 25))
      expect(described_class.parse_date("25 Apr 2026")).to eq(Date.new(2026, 4, 25))
    end

    it "refuses the shape with two readings" do
      expect(described_class.parse_date("01/04/2026")).to be_nil
    end

    it "refuses text that is not a date" do
      expect(described_class.parse_date("not a date")).to be_nil
      expect(described_class.parse_date(nil)).to be_nil
    end
  end

  describe "the published surface" do
    it "lists every function once, sorted" do
      expect(described_class::ALL).to eq(described_class::ALL.uniq.sort)
    end

    it "is exactly the built-ins plus what we register" do
      expect(described_class::ALL).to match_array(described_class::BUILT_IN + described_class::ADDED)
    end

    # A function reaches an author only if it is in ALL: the host rejects
    # anything outside it as err_formula_unknown_function before evaluating. So
    # registering one and forgetting to list it ships it unreachable, which is
    # what happened to `date` — registered, typed, and refused for every author
    # who typed it.
    it "publishes every function install registers" do
      calculator = described_class.install(Dentaku::Calculator.new)
      # No public reader for it, and the point of this spec is to read exactly
      # what install() put there rather than a list that can drift from it.
      registered = calculator.instance_variable_get(:@function_registry).keys.map(&:to_s)

      expect(registered - described_class::ALL).to be_empty
    end
  end
end
