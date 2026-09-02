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
      it "is symmetric" do
        forward = calculator.evaluate!(%{datediff(#{later}, #{earlier}, "days")})
        backward = calculator.evaluate!(%{datediff(#{earlier}, #{later}, "days")})

        expect(forward).to eq(-backward)
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

  describe "the published surface" do
    it "lists every function once, sorted" do
      expect(described_class::ALL).to eq(described_class::ALL.uniq.sort)
    end

    it "is exactly the built-ins plus what we register" do
      expect(described_class::ALL).to match_array(described_class::BUILT_IN + described_class::ADDED)
    end
  end
end
