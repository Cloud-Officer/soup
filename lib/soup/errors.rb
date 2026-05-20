# frozen_string_literal: true

module SOUP
  # Base class for all soup-raised errors. Inherits from StandardError so the
  # top-level rescue in bin/soup.rb (and any caller using `rescue` without
  # an explicit class) still catches every soup-internal error.
  class Error < StandardError; end

  # Raised when a soup configuration file (--licenses_file, --exceptions_file)
  # is missing, unreadable, or contains malformed JSON.
  class ConfigurationError < Error; end

  # Raised when an input lockfile is structurally malformed, unsupported, or
  # otherwise cannot be processed by the parser.
  class InvalidLockfileError < Error; end

  # Raised when a lockfile is recognized but its format version is not
  # supported (Yarn Berry, npm v1, etc.). A more specific InvalidLockfileError.
  class UnsupportedFormatError < InvalidLockfileError; end

  # Raised when a package metadata lookup against a remote registry fails in
  # an unrecoverable way (non-2xx after retries, or registry rejects the
  # request entirely).
  class RegistryError < Error; end

  # Raised when registry authentication fails (401 / "Bad credentials" from
  # GitHub API, etc.). A more specific RegistryError.
  class AuthenticationError < RegistryError; end

  # Raised when a registry returns a rate-limit response (403/429 with a
  # rate-limit message from GitHub API, etc.). A more specific RegistryError.
  class RateLimitError < RegistryError; end

  # Raised when the user is expected to supply missing metadata (risk level,
  # requirements, verification reasoning) but the run was invoked with
  # --no_prompt or the metadata is still missing after prompting.
  class MissingMetadataError < Error; end
end
