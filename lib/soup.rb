# frozen_string_literal: true

module SOUP
  PACKAGE_MANAGERS = %w[buildscript-gradle.lockfile composer.lock Gemfile.lock Package.resolved package-lock.json Podfile.lock requirements.txt yarn.lock].freeze
  RISK_LEVELS_SCREEN =
    [
      'Low (can’t lead to harm)',
      'Medium (can lead to reversible harm)',
      'High (can lead to irreversible harm)'
    ].freeze

  private_constant :PACKAGE_MANAGERS
  private_constant :RISK_LEVELS_SCREEN
end
