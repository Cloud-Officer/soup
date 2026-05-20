# frozen_string_literal: true

# TEST-03: pin the exit-code contract so a rename or accidental constant churn
# in lib/soup/status.rb breaks specs immediately rather than silently shifting
# the CLI's exit semantics.

RSpec.describe(SOUP::Status) do
  it 'exposes SUCCESS_EXIT_CODE as 0' do
    expect(described_class::SUCCESS_EXIT_CODE).to(eq(0))
  end

  it 'exposes ERROR_EXIT_CODE as 1' do
    expect(described_class::ERROR_EXIT_CODE).to(eq(1))
  end

  it 'does not define a third exit code', :aggregate_failures do
    # Guard against re-introducing the previously-unused FAILURE_EXIT_CODE = 2
    # without wiring it into a real code path.
    expect(described_class.constants).to(contain_exactly(:SUCCESS_EXIT_CODE, :ERROR_EXIT_CODE))
    expect { described_class::FAILURE_EXIT_CODE }
      .to(raise_error(NameError))
  end
end
