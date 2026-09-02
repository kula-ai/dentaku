require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::Result do
  let(:diagnostic) { Kula::Formula::Diagnostic.new(code: "err_x", position: 3, detail: {a: 1}) }

  it "is valid when nothing went wrong" do
    expect(described_class.new(source: "1 + 1", stored: "1 + 1")).to be_valid
  end

  it "is invalid once anything is reported" do
    expect(described_class.new(source: "x", diagnostics: [diagnostic])).not_to be_valid
  end

  it "exposes the codes for tagging and translation" do
    expect(described_class.new(source: "x", diagnostics: [diagnostic]).codes).to eq(["err_x"])
  end

  it "carries the source through to_h, so a caller can echo what was typed" do
    result = described_class.new(source: "1 + 1", stored: "1 + 1", dependencies: %w[f_1])

    expect(result.to_h).to eq({valid: true, source: "1 + 1", stored: "1 + 1", dependencies: %w[f_1], diagnostics: []})
  end

  it "omits blank keys from a diagnostic" do
    expect(Kula::Formula::Diagnostic.new(code: "err_x").to_h).to eq({code: "err_x"})
  end

  describe ".failure" do
    it "flattens diagnostics and leaves the rest empty" do
      result = described_class.failure("x", [diagnostic, diagnostic])

      expect(result).not_to be_valid
      expect(result.stored).to be_nil
      expect(result.diagnostics.size).to eq(2)
    end
  end

  it "publishes a bounded set of codes for a host's message catalogue" do
    expect(Kula::Formula::Errors::ALL).to all(be_a(String))
    expect(Kula::Formula::Errors::ALL).to eq(Kula::Formula::Errors::ALL.uniq)
  end
end
