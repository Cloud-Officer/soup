# frozen_string_literal: true

module SOUP
  module Status
    # Process exit codes used by bin/soup.rb. SUCCESS is the normal happy path;
    # ERROR covers every failure (validate_config!, parser raises, license
    # violations, OptionParser parse errors). A separate FAILURE_EXIT_CODE = 2
    # was defined here historically but never referenced, so it was removed to
    # drop dead code.
    SUCCESS_EXIT_CODE = 0
    ERROR_EXIT_CODE = 1

    public_constant :SUCCESS_EXIT_CODE
    public_constant :ERROR_EXIT_CODE
  end
end
