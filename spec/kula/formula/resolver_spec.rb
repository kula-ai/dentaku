require "spec_helper"
require "kula/formula"

RSpec.describe Kula::Formula::Resolver do
  subject(:resolver) { described_class.new(references) }

  let(:ref) { described_class::Reference }
  let(:references) do
    [
      ref.new(handle: "f_412", token: "Base salary", kind: :numeric),
      ref.new(handle: "f_413", token: "Bonus %", kind: :numeric),
      ref.new(handle: "s_start_date", token: "Start date", kind: :numeric)
    ]
  end

  describe "#to_storage" do
    it "rewrites tokens to handles" do
      expect(resolver.to_storage("{Base salary} * (1 + {Bonus %} / 100)"))
        .to eq("f_412 * (1 + f_413 / 100)")
    end

    it "matches tokens case- and whitespace-insensitively" do
      expect(resolver.to_storage("{base salary}")).to eq("f_412")
      expect(resolver.to_storage("{  Base   salary  }")).to eq("f_412")
    end

    it "preserves newlines and indentation" do
      expect(resolver.to_storage("{Base salary}\n  + {Bonus %}")).to eq("f_412\n  + f_413")
    end

    it "reports an unknown token with its position" do
      expect { resolver.to_storage("{Base salary} + {Nonsense}") }
        .to raise_error(described_class::UnknownToken) { |error|
          expect(error.token).to eq("Nonsense")
          expect(error.position).to eq(16)
        }
    end

    # Text between quotes is data. A brace inside it is not a field reference,
    # and treating it as one rejects a perfectly valid formula.
    it "leaves braces inside a string literal alone" do
      expect(resolver.to_storage(%{equaltext({Base salary}, "{n/a}")}))
        .to eq(%{equaltext(f_412, "{n/a}")})
    end

    it "handles single-quoted literals too" do
      expect(resolver.to_storage(%{equaltext({Base salary}, '{n/a}')}))
        .to eq(%{equaltext(f_412, '{n/a}')})
    end
  end

  describe "#to_display" do
    it "rewrites handles back to tokens" do
      expect(resolver.to_display("f_412 * (1 + f_413 / 100)"))
        .to eq("{Base salary} * (1 + {Bonus %} / 100)")
    end

    it "round-trips" do
      source = "{Base salary} * (1 + {Bonus %} / 100)"

      expect(resolver.to_display(resolver.to_storage(source))).to eq(source)
    end

    # A rename shows up everywhere at once, which is why storage is handle-based.
    it "renders the current token after a rename" do
      renamed = described_class.new([ref.new(handle: "f_412", token: "Annual base")])

      expect(renamed.to_display("f_412 * 2")).to eq("{Annual base} * 2")
    end

    # The author has to be able to see what broke.
    it "leaves a handle it does not know as-is" do
      expect(resolver.to_display("f_412 + f_999")).to eq("{Base salary} + f_999")
    end

    it "does not rewrite a handle-shaped word inside a literal" do
      expect(resolver.to_display(%{contains("f_412", f_413)})).to eq(%{contains("f_412", {Bonus %})})
    end
  end

  describe "#dependencies" do
    it "lists handles in first-appearance order" do
      expect(resolver.dependencies("f_413 + f_412 * f_413")).to eq(%w[f_413 f_412])
    end

    it "is empty when nothing is referenced" do
      expect(resolver.dependencies("1 + 2")).to eq([])
    end

    it "ignores handles it does not know" do
      expect(resolver.dependencies("f_412 + f_999")).to eq(%w[f_412])
    end

    # A false dependency is persisted and then feeds the graph, fabricating an
    # edge that skews ordering and can manufacture a phantom cycle.
    it "does not treat a handle-shaped word inside a literal as a dependency" do
      expect(resolver.dependencies(%{contains("f_413", f_412)})).to eq(%w[f_412])
    end
  end

  describe "#dangling" do
    it "reports references to fields it has never heard of" do
      expect(resolver.dangling("f_412 + f_999 + s_gone")).to eq(%w[f_999 s_gone])
    end

    it "is empty when every reference resolves" do
      expect(resolver.dangling("f_412 + f_413")).to eq([])
    end

    it "ignores handle-shaped words inside literals" do
      expect(resolver.dangling(%{contains("f_999", f_412)})).to eq([])
    end
  end

  # Normalisation deliberately widens what collides, so two genuinely different
  # fields can land on one key. Keeping the last silently would make a formula
  # read the wrong field.
  describe "ambiguous tokens" do
    it "refuses two references that normalise to the same token" do
      expect {
        described_class.new([
          ref.new(handle: "f_1", token: "Base Salary"),
          ref.new(handle: "f_2", token: "base  salary")
        ])
      }.to raise_error(described_class::AmbiguousToken, /base  salary/)
    end
  end
end
