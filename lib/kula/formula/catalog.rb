# frozen_string_literal: true

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
      SECONDS_PER_DAY = 86_400
      DEFAULT_ZONE = "UTC"

      # Registered on top of dentaku's built-ins.
      ADDED = %w[
        ceiling floor dateadd datediff year month day today
        equaltext upper lower trim contains coalesce ifnull isnull
      ].freeze

      # Supplied by dentaku itself, listed so a host can offer one surface.
      BUILT_IN = %w[round abs min max concat len].freeze

      ALL = (BUILT_IN + ADDED).sort.freeze

      class << self
        def install(calculator, zone: DEFAULT_ZONE)
          numeric(calculator)
          dates(calculator, zone)
          text(calculator)
          nulls(calculator)
          calculator
        end

        private

        def numeric(calculator)
          calculator.add_function(:ceiling, :numeric, ->(number) { number&.ceil })
          calculator.add_function(:floor, :numeric, ->(number) { number&.floor })
        end

        def dates(calculator, zone)
          calculator.add_function(:today, :numeric, -> { from_date(now(zone).to_date, zone) })

          calculator.add_function(:dateadd, :numeric, ->(timestamp, amount, unit) {
            next nil if timestamp.nil? || amount.nil?

            from_date(advance(to_date(timestamp, zone), amount.to_i, unit), zone)
          })

          calculator.add_function(:datediff, :numeric, ->(later, earlier, unit) {
            next nil if later.nil? || earlier.nil?

            difference(later.to_i, earlier.to_i, unit, zone)
          })

          calculator.add_function(:year, :numeric, ->(ts) { ts && to_date(ts, zone).year })
          calculator.add_function(:month, :numeric, ->(ts) { ts && to_date(ts, zone).month })
          calculator.add_function(:day, :numeric, ->(ts) { ts && to_date(ts, zone).day })
        end

        def text(calculator)
          calculator.add_function(:upper, :string, ->(text) { text&.to_s&.upcase })
          calculator.add_function(:lower, :string, ->(text) { text&.to_s&.downcase })
          calculator.add_function(:trim, :string, ->(text) { text&.to_s&.strip })

          # Case-insensitive by design: comparing against an option label should
          # not require matching its casing.
          calculator.add_function(:equaltext, :logical, ->(left, right) {
            left.to_s.casecmp?(right.to_s)
          })

          # Overrides dentaku's list-membership CONTAINS with substring search,
          # which is what a text formula means by it.
          calculator.add_function(:contains, :logical, ->(haystack, needle) {
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
          time = ::Time.at(timestamp.to_i)
          (time.respond_to?(:in_time_zone) ? time.in_time_zone(zone) : time.utc).to_date
        end

        def from_date(date, zone)
          date.respond_to?(:in_time_zone) ? date.in_time_zone(zone).to_i : date.to_time.utc.to_i
        end

        def advance(date, amount, unit)
          case unit.to_s.downcase
          when "week", "weeks" then date + (amount * 7)
          when "month", "months" then date >> amount
          when "year", "years" then date >> (amount * 12)
          else date + amount
          end
        end

        def difference(later, earlier, unit, zone)
          days = (later - earlier) / SECONDS_PER_DAY

          case unit.to_s.downcase
          when "week", "weeks" then days / 7
          when "month", "months" then months_between(later, earlier, zone)
          when "year", "years" then months_between(later, earlier, zone) / 12
          else days
          end
        end

        def months_between(later, earlier, zone)
          a = to_date(later, zone)
          b = to_date(earlier, zone)
          ((a.year - b.year) * 12) + (a.month - b.month) - (a.day < b.day ? 1 : 0)
        end
      end
    end
  end
end
