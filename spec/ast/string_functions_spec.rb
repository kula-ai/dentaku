require 'spec_helper'
require 'dentaku/ast/functions/string_functions'

describe Dentaku::AST::StringFunctions::Left do
  let(:string) { identifier('string') }
  let(:length) { identifier('length') }

  subject { described_class.new(string, length) }

  it 'returns the left N characters of the string' do
    expect(subject.value('string' => 'ABCDEFG', 'length' => 4)).to eq 'ABCD'
  end

  it 'works correctly with literals' do
    left = literal('ABCD')
    len  = literal(2)
    fn   = described_class.new(left, len)
    expect(fn.value).to eq 'AB'
  end

  it 'handles an empty string correctly' do
    expect(subject.value('string' => '', 'length' => 4)).to eq ''
  end

  it 'handles size greater than input string length correctly' do
    expect(subject.value('string' => 'abcdefg', 'length' => 40)).to eq 'abcdefg'
  end

  it 'accepts strings as length if they can be parsed to a number' do
    expect(subject.value('string' => 'ABCDEFG', 'length' => '4')).to eq 'ABCD'
  end

  it 'has the proper type' do
    expect(subject.type).to eq(:string)
  end

  it 'raises an error if given invalid length' do
    expect {
      subject.value('string' => 'abcdefg', 'length' => -2)
    }.to raise_error(Dentaku::ArgumentError, /LEFT\(\) requires length to be positive/)
  end

  it 'raises an error when given a junk length' do
    expect {
      subject.value('string' => 'abcdefg', 'length' => 'junk')
    }.to raise_error(Dentaku::ArgumentError, "'junk' is not coercible to numeric")
  end
end

describe Dentaku::AST::StringFunctions::Right do
  it 'returns the right N characters of the string' do
    subject = described_class.new(literal('ABCDEFG'), literal(4))
    expect(subject.value).to eq 'DEFG'
  end

  it 'handles an empty string correctly' do
    subject = described_class.new(literal(''), literal(4))
    expect(subject.value).to eq ''
  end

  it 'handles size greater than input string length correctly' do
    subject = described_class.new(literal('abcdefg'), literal(40))
    expect(subject.value).to eq 'abcdefg'
  end

  it 'accepts strings as length if they can be parsed to a number' do
    subject = described_class.new(literal('ABCDEFG'), literal('4'))
    expect(subject.value).to eq 'DEFG'
  end

  it 'has the proper type' do
    expect(subject.type).to eq(:string)
  end

  it 'raises an error when given a junk length' do
    subject = described_class.new(literal('abcdefg'), literal('junk'))
    expect { subject.value }.to raise_error(Dentaku::ArgumentError, "'junk' is not coercible to numeric")
  end
end

describe Dentaku::AST::StringFunctions::Mid do
  it 'returns a substring from the middle of the string' do
    subject = described_class.new(literal('ABCDEFG'), literal(4), literal(2))
    expect(subject.value).to eq 'DE'
  end

  it 'handles an empty string correctly' do
    subject = described_class.new(literal(''), literal(4), literal(2))
    expect(subject.value).to eq ''
  end

  it 'handles offset greater than input string length correctly' do
    subject = described_class.new(literal('abcdefg'), literal(40), literal(4))
    expect(subject.value).to eq ''
  end

  it 'handles size greater than input string length correctly' do
    subject = described_class.new(literal('abcdefg'), literal(4), literal(40))
    expect(subject.value).to eq 'defg'
  end

  it 'accepts strings as offset and length if they can be parsed to a number' do
    subject = described_class.new(literal('ABCDEFG'), literal('4'), literal('2'))
    expect(subject.value).to eq 'DE'
  end

  it 'has the proper type' do
    expect(subject.type).to eq(:string)
  end

  it 'raises an error when given a junk offset' do
    subject = described_class.new(literal('abcdefg'), literal('junk offset'), literal(2))
    expect { subject.value }.to raise_error(Dentaku::ArgumentError, "'junk offset' is not coercible to numeric")
  end

  it 'raises an error when given a junk length' do
    subject = described_class.new(literal('abcdefg'), literal(4), literal('junk'))
    expect { subject.value }.to raise_error(Dentaku::ArgumentError, "'junk' is not coercible to numeric")
  end
end

describe Dentaku::AST::StringFunctions::Len do
  it 'returns the length of a string' do
    subject = described_class.new(literal('ABCDEFG'))
    expect(subject.value).to eq 7
  end

  it 'handles an empty string correctly' do
    subject = described_class.new(literal(''))
    expect(subject.value).to eq 0
  end

  it 'has the proper type' do
    expect(subject.type).to eq(:numeric)
  end
end

describe Dentaku::AST::StringFunctions::Find do
  it 'returns the position of a substring within a string' do
    subject = described_class.new(literal('DE'), literal('ABCDEFG'))
    expect(subject.value).to eq 4
  end

  it 'handles an empty substring correctly' do
    subject = described_class.new(literal(''), literal('ABCDEFG'))
    expect(subject.value).to eq 1
  end

  it 'handles an empty string correctly' do
    subject = described_class.new(literal('DE'), literal(''))
    expect(subject.value).to be_nil
  end

  it 'has the proper type' do
    expect(subject.type).to eq(:numeric)
  end
end

describe Dentaku::AST::StringFunctions::Substitute do
  it 'replaces a substring within a string' do
    subject = described_class.new(literal('ABCDEFG'), literal('DE'), literal('xy'))
    expect(subject.value).to eq 'ABCxyFG'
  end

  it 'handles an empty search string correctly' do
    subject = described_class.new(literal('ABCDEFG'), literal(''), literal('xy'))
    expect(subject.value).to eq 'xyABCDEFG'
  end

  it 'handles an empty replacement string correctly' do
    subject = described_class.new(literal('ABCDEFG'), literal('DE'), literal(''))
    expect(subject.value).to eq 'ABCFG'
  end

  it 'has the proper type' do
    expect(subject.type).to eq(:string)
  end
end

describe Dentaku::AST::StringFunctions::Concat do
  it 'concatenates two strings' do
    subject = described_class.new(literal('ABC'), literal('DEF'))
    expect(subject.value).to eq 'ABCDEF'
  end

  it 'concatenates a string onto an empty string' do
    subject = described_class.new(literal(''), literal('ABC'))
    expect(subject.value).to eq 'ABC'
  end

  it 'concatenates an empty string onto a string' do
    subject = described_class.new(literal('ABC'), literal(''))
    expect(subject.value).to eq 'ABC'
  end

  it 'concatenates two empty strings' do
    subject = described_class.new(literal(''), literal(''))
    expect(subject.value).to eq ''
  end

  # to_s is wrong for both numeric types a formula carries: a Float writes 234 as
  # "234.0" and a BigDecimal as "0.234e3". Neither belongs in an offer letter.
  it 'writes a whole number without a decimal tail, whatever its type' do
    [234, 234.0, BigDecimal('234')].each do |number|
      subject = described_class.new(literal(number), literal('x'))
      expect(subject.value).to eq('234x'), number.class.to_s
    end
  end

  it 'writes a fraction in full rather than in scientific notation' do
    expect(described_class.new(literal(BigDecimal('1.5'))).value).to eq('1.5')
    expect(described_class.new(literal(1.5)).value).to eq('1.5')
    expect(described_class.new(literal(BigDecimal('0.1'))).value).to eq('0.1')
  end

  # BigDecimal#to_s("F") leaves the zeros behind.
  it 'drops the trailing zeros of a fraction' do
    expect(described_class.new(literal(BigDecimal('1.50'))).value).to eq('1.5')
  end

  # A Float small enough to render in exponent notation reached the trailing-zero
  # strip as text, so "1.5e-10" came out as "1.5e-1" -- nine orders of magnitude
  # out, with nothing raised. Routed through BigDecimal, which has a plain form.
  it 'writes a Float exponent in full rather than truncating it' do
    expect(described_class.new(literal(1.5e-10)).value).to eq('0.00000000015')
    expect(described_class.new(literal(1.5e-5)).value).to eq('0.000015')
  end

  # to_i raises FloatDomainError on these, and that is not a Dentaku::Error -- so
  # it would leave evaluate! as a 500 rather than a diagnostic.
  it 'writes a non-finite number rather than raising' do
    expect(described_class.new(literal(Float::INFINITY)).value).to eq('Infinity')
    expect(described_class.new(literal(Float::NAN)).value).to eq('NaN')
    expect(described_class.new(literal(BigDecimal('Infinity'))).value).to eq('Infinity')
  end

  it 'has the proper type' do
    expect(subject.type).to eq(:string)
  end
end

describe Dentaku::AST::StringFunctions::Contains do
  it 'checks for substrings' do
    subject = described_class.new(literal('app'), literal('apple'))
    expect(subject.value).to be_truthy
    subject = described_class.new(literal('app'), literal('orange'))
    expect(subject.value).to be_falsy
  end

  it 'has the proper type' do
    expect(subject.type).to eq(:logical)
  end
end
