module Dentaku
  # Rewrites Kula's chained conditional into dentaku's nested three-arg form:
  #
  #   if(a, b) else if(c, d) else(e)   ->   if(a, b, if(c, d, e))
  #
  # Operates on the token stream rather than the source string, so every token
  # keeps the position it was scanned at and parse errors still point into what
  # the user actually typed.
  #
  # Skipped inside `case ... end`, where `else` is dentaku's own keyword.
  class ChainRewriter
    def self.rewrite(tokens)
      new(tokens).rewrite
    end

    def initialize(tokens)
      @tokens = tokens
    end

    def rewrite
      out = []
      unclosed = 0
      case_depth = 0
      i = 0

      while i < @tokens.length
        token = @tokens[i]

        if token.is?(:case)
          case_depth += 1 if token.value == :open
          case_depth -= 1 if token.value == :close
        end

        if case_depth.zero? && closes_a_chain_link?(i)
          following = @tokens[i + 2]

          if if_function?(following)
            # ") else if("  ->  ", if("   — the nested if becomes the false branch
            out << comma_at(token.position)
            unclosed += 1
            i += 2
            next
          elsif open_paren?(following)
            # ") else ("  ->  ","        — else's parens are dropped entirely
            out << comma_at(token.position)
            i += 3
            next
          end
        end

        if case_depth.zero? && token.is?(:case) && token.value == :else
          raise ParseError.for(:orphan_else, position: token.position)
        end

        out << token
        i += 1
      end

      last = out.last
      unclosed.times { out << close_at(last&.position) }
      out
    end

    private

    def closes_a_chain_link?(index)
      token = @tokens[index]
      nxt = @tokens[index + 1]
      token.is?(:grouping) && token.value == :close &&
        nxt&.is?(:case) && nxt.value == :else
    end

    def if_function?(token)
      token&.is?(:function) && token.value == :if
    end

    def open_paren?(token)
      token&.is?(:grouping) && token.value == :open
    end

    def comma_at(position)
      build(:grouping, :comma, ",", position)
    end

    def close_at(position)
      build(:grouping, :close, ")", position)
    end

    def build(category, value, raw, position)
      Token.new(category, value, raw).tap { |t| t.position = position }
    end
  end
end
