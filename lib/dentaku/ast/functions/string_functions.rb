require_relative '../function'

module Dentaku
  module AST
    module StringFunctions
      # Where the host states its display scale for one evaluation. A reserved
      # key in the evaluation context, the way dentaku carries __evaluation_mode:
      # these functions are AST classes and get nothing but +context+, so there
      # is no constructor to pass it to. Two leading underscores cannot collide
      # with a field handle, which is f_<id> or s_<token>.
      SCALE_KEY = "__display_scale"

      def self.scale_in(context)
        context[SCALE_KEY] if context.is_a?(::Hash)
      end

      # A number as a person would write it, for any function that turns one into
      # text. `to_s` is wrong for both numeric types a formula carries: a Float
      # renders 234 as "234.0", and a BigDecimal -- which is what a cast number
      # field produces -- renders it as "0.234e3". Neither belongs in an offer
      # letter.
      #
      # An integral value loses the decimal tail; a fractional one is written in
      # full rather than in scientific notation, and without the trailing zeros
      # BigDecimal#to_s("F") leaves behind.
      #
      # +scale+ is the number of decimal places the HOST displays a number at.
      # Without it, a non-terminating division kept every digit the division
      # produced: concat("", 100000/3) wrote 33 decimals into an offer letter
      # where the same expression in a number field showed 33333.3333, and
      # len()/contains() answered on the long form -- 33 rather than 10, and a
      # twelve-digit run of threes matching something no reader can see. Only
      # the caller knows that scale, so it is passed in rather than assumed; nil
      # keeps the full precision, which is what a host with no display rule
      # wants.
      def self.humanize(value, scale = nil)
        return value.to_s unless value.is_a?(::Numeric)
        # Infinity and NaN have no decimal form: to_i raises FloatDomainError on
        # them, which is not a Dentaku::Error and so would leave evaluate! as a
        # 500 rather than a diagnostic. to_s is the honest answer.
        return value.to_s if value.respond_to?(:finite?) && !value.finite?
        return value.to_i.to_s if value.respond_to?(:to_i) && value == value.to_i

        # Through BigDecimal, which has a plain-decimal form. A Float small or
        # large enough to render in exponent notation reached the trailing-zero
        # strip as text, and "1.5e-10" came out as "1.5e-1" -- nine orders of
        # magnitude out, silently. No formula path produces a Float today; this
        # is so the next caller that does is not the one who finds out.
        value = ::Kernel::BigDecimal(value.to_s) if value.is_a?(::Float)
        # half: :even to match the host's own rounding of a numeric result, so
        # one number cannot render two ways depending on which layer printed it.
        # Rounded before the strip, because rounding is what creates the trailing
        # zeros the strip then removes: 5.10 at scale 4 is "5.1", not "5.1000".
        value = value.round(scale, half: :even) if scale && value.is_a?(::BigDecimal)
        decimal = value.is_a?(::BigDecimal) ? value.to_s("F") : value.to_s
        decimal.include?(".") ? decimal.sub(%r{0+\z}, "").sub(%r{\.\z}, "") : decimal
      end

      class Base < Function
        def type
          :string
        end

        def negative_argument_failure(fun, arg = 'length')
          raise Dentaku::ArgumentError.for(
            :invalid_value,
            function_name: "#{fun}()"
          ), "#{fun}() requires #{arg} to be positive"
        end
      end

      class Left < Base
        def self.min_param_count
          2
        end

        def self.max_param_count
          2
        end

        def initialize(*args)
          super
          @string, @length = *@args
        end

        def value(context = {})
          string = StringFunctions.humanize(@string.value(context), StringFunctions.scale_in(context))
          length = Dentaku::NumericParser.ensure_numeric!(@length.value(context)).to_i
          negative_argument_failure('LEFT') if length < 0
          string[0, length]
        end
      end

      class Right < Base
        def self.min_param_count
          2
        end

        def self.max_param_count
          2
        end

        def initialize(*args)
          super
          @string, @length = *@args
        end

        def value(context = {})
          string = StringFunctions.humanize(@string.value(context), StringFunctions.scale_in(context))
          length = Dentaku::NumericParser.ensure_numeric!(@length.value(context)).to_i
          negative_argument_failure('RIGHT') if length < 0
          string[length * -1, length] || string
        end
      end

      class Mid < Base
        def self.min_param_count
          3
        end

        def self.max_param_count
          3
        end

        def initialize(*args)
          super
          @string, @offset, @length = *@args
        end

        def value(context = {})
          string = StringFunctions.humanize(@string.value(context), StringFunctions.scale_in(context))
          offset = Dentaku::NumericParser.ensure_numeric!(@offset.value(context)).to_i
          negative_argument_failure('MID', 'offset') if offset < 0
          length = Dentaku::NumericParser.ensure_numeric!(@length.value(context)).to_i
          negative_argument_failure('MID') if length < 0
          string[offset - 1, length].to_s
        end
      end

      class Len < Base
        def self.min_param_count
          1
        end

        def self.max_param_count
          1
        end

        def initialize(*args)
          super
          @string = @args[0]
        end

        def value(context = {})
          string = StringFunctions.humanize(@string.value(context), StringFunctions.scale_in(context))
          string.length
        end

        def type
          :numeric
        end
      end

      class Find < Base
        def self.min_param_count
          2
        end

        def self.max_param_count
          2
        end

        def initialize(*args)
          super
          @needle, @haystack = *@args
        end

        def value(context = {})
          needle = @needle.value(context)
          needle = StringFunctions.humanize(needle, StringFunctions.scale_in(context)) unless needle.is_a?(Regexp)
          haystack = StringFunctions.humanize(@haystack.value(context), StringFunctions.scale_in(context))
          pos = haystack.index(needle)
          pos && pos + 1
        end

        def type
          :numeric
        end
      end

      class Substitute < Base
        def self.min_param_count
          3
        end

        def self.max_param_count
          3
        end

        def initialize(*args)
          super
          @original, @search, @replacement = *@args
        end

        def value(context = {})
          original = StringFunctions.humanize(@original.value(context), StringFunctions.scale_in(context))
          search = @search.value(context)
          search = StringFunctions.humanize(search, StringFunctions.scale_in(context)) unless search.is_a?(Regexp)
          replacement = StringFunctions.humanize(@replacement.value(context), StringFunctions.scale_in(context))
          original.sub(search, replacement)
        end
      end

      class Concat < Base
        def self.min_param_count
          1
        end

        def self.max_param_count
          Float::INFINITY
        end

        def initialize(*args)
          super
        end

        def value(context = {})
          @args.map { |arg| Dentaku::AST::StringFunctions.humanize(arg.value(context), Dentaku::AST::StringFunctions.scale_in(context)) }.join
        end
      end

      class Contains < Base
        def self.min_param_count
          2
        end

        def self.max_param_count
          2
        end

        def initialize(*args)
          super
          @needle, @haystack = *args
        end

        def value(context = {})
          StringFunctions.humanize(@haystack.value(context), StringFunctions.scale_in(context))
            .include?(StringFunctions.humanize(@needle.value(context), StringFunctions.scale_in(context)))
        end

        def type
          :logical
        end
      end
    end
  end
end

Dentaku::AST::Function.register_class(:left,       Dentaku::AST::StringFunctions::Left)
Dentaku::AST::Function.register_class(:right,      Dentaku::AST::StringFunctions::Right)
Dentaku::AST::Function.register_class(:mid,        Dentaku::AST::StringFunctions::Mid)
Dentaku::AST::Function.register_class(:len,        Dentaku::AST::StringFunctions::Len)
Dentaku::AST::Function.register_class(:find,       Dentaku::AST::StringFunctions::Find)
Dentaku::AST::Function.register_class(:substitute, Dentaku::AST::StringFunctions::Substitute)
Dentaku::AST::Function.register_class(:concat,     Dentaku::AST::StringFunctions::Concat)
Dentaku::AST::Function.register_class(:contains,   Dentaku::AST::StringFunctions::Contains)
