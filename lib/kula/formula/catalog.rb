# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module Kula
  module Formula
    # The function surface a formula may use.
    #
    # Dentaku already supplies round, abs, min, max, concat and len; everything
    # else here is registered onto the calculator.
    #
    # Date functions take and return integer UNIX timestamps rather than Date
    # objects, so a host application storing dates as integers never has to
    # convert. They read those integers in a caller-supplied zone: reading them
    # as UTC when the application displays them in a local zone makes year() and
    # day() disagree with the date shown for the very same value.
    #
    # Every function tolerates nil. A formula referencing an unanswered field
    # yields nil, and that nil has to reach the top as "not computable yet"
    # rather than raising part-way through a save.
    module Catalog
      DEFAULT_ZONE = "UTC"

      # Registered on top of dentaku's built-ins.
      ADDED = %w[
        ceiling floor date parsedate dateadd datediff year month day today
        equaltext upper lower trim contains coalesce ifnull isnull
      ].freeze

      # Supplied by dentaku itself, listed so a host can offer one surface. +if+
      # is dentaku's own; this fork only relaxes its arity to allow the two-arg
      # form and the chained else-if. and/or/not are listed because dentaku
      # parses their infix forms as operators but their call forms as functions —
      # rejecting not(x) while accepting `a and b` would be an arbitrary split.
      BUILT_IN = %w[round abs min max concat len if and or not].freeze

      ALL = (BUILT_IN + ADDED).sort.freeze

      class << self
        def install(calculator, zone: DEFAULT_ZONE)
          numeric(calculator)
          dates(calculator, zone)
          text(calculator)
          nulls(calculator)
          calculator
        end

        # Public: the host parses a typed date too — a field's DEFAULT value is
        # authored in the drawer, not in a formula — and which shapes are
        # accepted has to be one rule, not two that drift.
        def parse_date(text)
          return nil if text.nil?

          value = text.to_s.strip
          return nil if value.empty?
          # Both parts could be a month, so there is no reading to prefer.
          # parsedate(text, format) is how an author says which they meant.
          if (parts = AMBIGUOUS_NUMERIC.match(value)) && parts[1].to_i <= 12 && parts[2].to_i <= 12
            return nil
          end

          begin
            # ISO first and explicitly: Date.parse reads 2026-04-01 correctly, but
            # stating it keeps the one format every system agrees on independent
            # of what Date.parse decides for the rest.
            ISO.match?(value) ? ::Date.iso8601(value) : ::Date.parse(value)
          rescue ::Date::Error, ::ArgumentError
            nil
          end
        end

        private

        def numeric(calculator)
          calculator.add_function(:ceiling, :numeric, ->(number) { as_number(number)&.ceil })
          calculator.add_function(:floor, :numeric, ->(number) { as_number(number)&.floor })
        end

        # add_function declares a return type, not argument types, and a field's
        # stored value can disagree with its declared kind — so a wrong-typed
        # operand reaches these lambdas. nil stays nil (an unanswered field), but
        # anything else that is not a number raises: without this, ceiling("abc")
        # is a NoMethodError past evaluate! to the host, and year("abc") reads 0
        # as 1970. Dentaku::ArgumentError because evaluate! already maps it.
        #
        # BigDecimal rather than Float: dentaku carries decimals as BigDecimal, and
        # Float would cap precision at ~15 digits and quietly accept "0x10".
        def as_number(value)
          return nil if value.nil?
          return value if value.is_a?(::Numeric)

          ::Kernel::BigDecimal(value.to_s)
        rescue ::ArgumentError, ::TypeError
          raise ::Dentaku::ArgumentError.for(:incompatible_type, value: value)
        end

        def dates(calculator, zone)
          calculator.add_function(:today, :numeric, -> { from_date(now(zone).to_date, zone) })

          # Date-granular: time-of-day is dropped, so dateadd(t, 0, "day") returns
          # midnight of t's day rather than t itself.
          calculator.add_function(:dateadd, :numeric, ->(timestamp, amount, unit) {
            next nil if timestamp.nil? || amount.nil?

            start = to_date(timestamp, zone)
            step = as_number(amount)
            moved = start && step && advance(start, step.to_i, unit)
            moved && from_date(moved, zone)
          })

          calculator.add_function(:datediff, :numeric, ->(later, earlier, unit) {
            next nil if later.nil? || earlier.nil?

            difference(later, earlier, unit, zone)
          })

          # The only way to name a date the form does not already hold. Without
          # it "the end of this year" can only be written as a literal, which is
          # correct until the year turns and silently wrong after — so a formula
          # meant to recur had an expiry date nobody could see.
          # Either three parts or one piece of text. The parts form cannot be
          # misread; the text form is the one an author reaches for, and it is
          # deliberately liberal about every shape that HAS one reading and
          # refuses the single shape that has two.
          calculator.add_function(:date, :numeric, ->(*args) {
            built =
              case args.length
              when 1 then parse_date(args.first)
              when 3 then build_date(*args)
              else raise ::Dentaku::ArgumentError.for(:wrong_number_of_arguments, function_name: "date")
              end
            built && from_date(built, zone)
          })

          # For the shape date() refuses. The format is the author's answer to
          # "which of these two numbers is the month", so it is theirs to give
          # rather than ours to guess.
          calculator.add_function(:parsedate, :numeric, ->(text, format) {
            next nil if text.nil? || format.nil?

            parsed = begin
              ::Date.strptime(text.to_s.strip, to_strptime(format.to_s))
            rescue ::Date::Error, ::ArgumentError
              nil
            end
            parsed && from_date(parsed, zone)
          })

          calculator.add_function(:year, :numeric, ->(ts) { to_date(ts, zone)&.year })
          calculator.add_function(:month, :numeric, ->(ts) { to_date(ts, zone)&.month })
          calculator.add_function(:day, :numeric, ->(ts) { to_date(ts, zone)&.day })
        end

        def text(calculator)
          calculator.add_function(:upper, :string, ->(text) { text&.to_s&.upcase })
          calculator.add_function(:lower, :string, ->(text) { text&.to_s&.downcase })
          calculator.add_function(:trim, :string, ->(text) { text&.to_s&.strip })

          # Case-insensitive by design: comparing against an option label should
          # not require matching its casing.
          calculator.add_function(:equaltext, :logical, ->(left, right) {
            # nil is "not answered", not "empty string": without this, two blank
            # fields would compare equal and a gate built on it would fire on
            # data nobody has filled in.
            next nil if left.nil? || right.nil?

            left.to_s.casecmp?(right.to_s)
          })

          # Upstream CONTAINS is already a substring test; this override only adds
          # case-insensitivity and nil tolerance. Argument order matches upstream
          # deliberately — needle first, haystack second — so a formula written
          # against dentaku's documented signature keeps its meaning.
          calculator.add_function(:contains, :logical, ->(needle, haystack) {
            next nil if needle.nil? || haystack.nil?

            haystack.to_s.downcase.include?(needle.to_s.downcase)
          })
        end

        def nulls(calculator)
          calculator.add_function(:coalesce, :numeric, ->(*values) { values.compact.first })
          calculator.add_function(:ifnull, :numeric, ->(value, fallback) { value.nil? ? fallback : value })
          calculator.add_function(:isnull, :logical, ->(value) { value.nil? })
        end

        # ActiveSupport supplies in_time_zone; fall back to UTC without it so the
        # gem stays usable outside Rails.
        def now(zone)
          ::Time.now.respond_to?(:in_time_zone) ? ::Time.now.in_time_zone(zone) : ::Time.now.utc
        end

        def to_date(timestamp, zone)
          seconds = as_number(timestamp)
          return nil if seconds.nil?

          time = ::Time.at(seconds.to_i)
          (time.respond_to?(:in_time_zone) ? time.in_time_zone(zone) : time.utc).to_date
        end

        # Without ActiveSupport there is no zone support at all, so fall back to
        # UTC midnight rather than system-local, matching to_date's fallback.
        def from_date(date, zone)
          return date.in_time_zone(zone).to_i if date.respond_to?(:in_time_zone)

          ::Time.utc(date.year, date.month, date.day).to_i
        end

        def build_date(year, month, day)
          return nil if year.nil? || month.nil? || day.nil?

          parts = [as_number(year), as_number(month), as_number(day)]
          return nil if parts.any?(&:nil?)

          begin
            ::Date.new(*parts.map(&:to_i))
          rescue ::Date::Error
            # A day that does not exist — 31 February — is not computable rather
            # than an authoring error: the parts can be fields.
            nil
          end
        end

        # Day-first and month-first cannot both be right, and 01/04/2026 is 1
        # April to most of the world and 4 January to the United States. Guessing
        # writes a plausible wrong date into a document nobody re-reads, so the
        # one genuinely ambiguous shape is refused and everything decidable is
        # accepted.
        AMBIGUOUS_NUMERIC = %r{\A(\d{1,2})[/-](\d{1,2})[/-](\d{4})\z}
        ISO = /\A\d{4}-\d{1,2}-\d{1,2}\z/

        # The tokens an author writes, mapped onto strptime's. No width variants:
        # strptime's %d and %m already read both "1" and "01", and the %-d form
        # is a strftime flag that strptime does not accept at all — so dd and d
        # are the same instruction to the parser, and differ only to the author.
        STRPTIME_TOKENS = {
          "yyyy" => "%Y", "yy" => "%y",
          "MMMM" => "%B", "MMM" => "%b", "MM" => "%m", "M" => "%m",
          "dd" => "%d", "d" => "%d"
        }.freeze

        def to_strptime(format)
          format.gsub(/yyyy|yy|MMMM|MMM|MM|M|dd|d/) { |token| STRPTIME_TOKENS.fetch(token) }
        end

        # An unrecognised unit yields nil rather than quietly meaning days: the
        # unit is an author-typed literal, so a typo is the expected failure and
        # should surface rather than produce a plausible wrong number.
        def advance(date, amount, unit)
          case unit.to_s.downcase
          when "day", "days" then date + amount
          when "week", "weeks" then date + (amount * 7)
          when "month", "months" then date >> amount
          when "year", "years" then date >> (amount * 12)
          end
        end

        # Whole days between the two dates, not raw epoch seconds: dividing
        # seconds disagrees with day() across a midnight boundary, and floors
        # negatives asymmetrically so datediff(a, b) != -datediff(b, a).
        def difference(later, earlier, unit, zone)
          to = to_date(later, zone)
          from = to_date(earlier, zone)
          return nil if to.nil? || from.nil?

          days = (to - from).to_i

          case unit.to_s.downcase
          when "day", "days" then days
          # truncate, not integer division: / floors toward -infinity, so
          # -64 / 7 is -10 while 64 / 7 is 9 and datediff(a, b) != -datediff(b, a).
          when "week", "weeks" then days.fdiv(7).truncate
          when "month", "months" then months_between(later, earlier, zone)
          when "year", "years" then months_between(later, earlier, zone).fdiv(12).truncate
          end
        end

        # Mirrored rather than computed directly when the arguments are the wrong
        # way round: the partial-month adjustment always rounds toward the past,
        # so computing both directions independently gives -3 against 2.
        def months_between(later, earlier, zone)
          a = to_date(later, zone)
          b = to_date(earlier, zone)
          return -months_between(earlier, later, zone) if a < b

          ((a.year - b.year) * 12) + (a.month - b.month) - (a.day < b.day ? 1 : 0)
        end
      end
    end
  end
end
