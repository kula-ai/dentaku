# Acceptance harness for the Kula fork. Encodes R-1 (the PRD author's grammar
# decisions) plus the two engine requirements dentaku upstream cannot meet.
#
#   ruby -Ilib kula_grammar_check.rb
require "dentaku"

$pass = 0
$fail = 0

def check(label)
  actual = yield
  ok = actual == :ok || actual == true
  puts format("  %-4s %s", ok ? "PASS" : "FAIL", label)
  ok ? $pass += 1 : $fail += 1
rescue => e
  puts format("  %-4s %s  -- %s: %s", "FAIL", label, e.class, e.message.to_s[0, 70])
  $fail += 1
end

def eq(label, expected)
  actual = yield
  ok = actual == expected
  puts format("  %-4s %-52s got %s", ok ? "PASS" : "FAIL", label, actual.inspect)
  ok ? $pass += 1 : $fail += 1
rescue => e
  puts format("  %-4s %-52s RAISED %s: %s", "FAIL", label, e.class, e.message.to_s[0, 50])
  $fail += 1
end

def calc = Dentaku::Calculator.new

puts "\n== R-1: two-arg if returns empty when false =="
eq("if(1>0, 10)", 10)          { calc.evaluate!("if(1>0, 10)") }
eq("if(1>2, 10) -> nil", nil)  { calc.evaluate!("if(1>2, 10)") }

puts "\n== R-1: chained else if / else =="
eq("first branch",  10) { calc.evaluate!("if(1>0, 10) else if(1>0, 20) else(30)") }
eq("middle branch", 20) { calc.evaluate!("if(1>2, 10) else if(1>0, 20) else(30)") }
eq("else branch",   30) { calc.evaluate!("if(1>2, 10) else if(2>3, 20) else(30)") }
eq("chain with no else -> nil", nil) { calc.evaluate!("if(1>2, 10) else if(2>3, 20)") }

puts "\n== R-1: chain equals the nested form =="
eq("chain",  20) { calc.evaluate!("if(1>2, 10) else if(1>0, 20) else(30)") }
eq("nested", 20) { calc.evaluate!("if(1>2, 10, if(1>0, 20, 30))") }

puts "\n== R-1: newlines and arbitrary whitespace between else and if =="
eq("multi-line chain", 20) { calc.evaluate!("if(1>2, 10)\n  else   if(1>0, 20)\n  else(30)") }

puts "\n== R-1: structural errors are rejected =="
check("orphan else() is a parse error") do
  begin; calc.evaluate!("else(30)"); false; rescue Dentaku::ParseError, Dentaku::TokenizerError; :ok; end
end
check("else before else if is a parse error") do
  begin; calc.evaluate!("if(1>0,1) else(2) else if(1>0,3)"); false; rescue Dentaku::ParseError, Dentaku::TokenizerError; :ok; end
end

puts "\n== Engine requirement: source positions =="
check("tokens carry a character offset") do
  t = Dentaku::Tokenizer.new.tokenize("12 + salary")
  t.map(&:position) == [0, 3, 5] ? :ok : (puts("       positions=#{t.map(&:position).inspect}"); false)
end
check("ParseError reports a position") do
  begin
    calc.evaluate!("1 + 2 foo")
    false
  rescue Dentaku::ParseError => e
    e.meta[:position] ? :ok : (puts("       meta=#{e.meta.inspect}"); false)
  end
end

puts "\n== Engine requirement: all lexical errors in one pass =="
check("two bad characters report two errors") do
  begin
    Dentaku::Tokenizer.new.tokenize("1 § 2 ¤ 3")
    false
  rescue Dentaku::TokenizerError => e
    (e.respond_to?(:errors) && e.errors.size == 2) ? :ok : (puts("       errors=#{e.respond_to?(:errors) ? e.errors.inspect : "n/a"}"); false)
  end
end

puts "\n== Regression: upstream behaviour still works =="
eq("arithmetic",    7)  { calc.evaluate!("1 + 2 * 3") }
eq("3-arg if",      10) { calc.evaluate!("if(1>0, 10, 20)") }
eq("identifiers",   107){ calc.evaluate!("f_base + f_bonus", {"f_base" => 100, "f_bonus" => 7}) }
eq("dependencies",  %w[a b c]) { calc.dependencies("a * b + c") }
eq("case/when",     "y"){ calc.evaluate!("case a when 1 then 'y' else 'n' end", {"a" => 1}) }

puts "\n#{'=' * 60}\n  #{$pass} passed, #{$fail} failed\n#{'=' * 60}\n"
exit($fail.zero? ? 0 : 1)
