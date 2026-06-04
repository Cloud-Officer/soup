# Architecture Design

## Table of Contents

- [Architecture diagram](#architecture-diagram)
- [Software units](#software-units)
- [Software of Unknown Provenance](#software-of-unknown-provenance)
- [Critical algorithms](#critical-algorithms)
- [Risk controls](#risk-controls)

## Architecture diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLI Entry Point                                 │
│                              bin/soup.rb                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                             SOUP::Application                                │
│                          lib/soup/application.rb                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │   detect    │  │    read     │  │    check    │  │       save          │ │
│  │  packages   │──│   cached    │──│  packages   │──│      files          │ │
│  │             │  │  packages   │  │             │  │                     │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
         │                                   │
         ▼                                   ▼
┌─────────────────────────┐    ┌──────────────────────────────────────────────┐
│    SOUP::Options        │    │              SOUP::Package                    │
│  lib/soup/options.rb    │    │           lib/soup/package.rb                 │
│                         │    │                                               │
│  Command-line parsing   │    │  Data model for package information           │
└─────────────────────────┘    └──────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Package Manager Parsers                            │
│                           lib/soup/parsers/                                  │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ │
│  │  Bundler   │ │  Composer  │ │   Gradle   │ │    NPM     │ │    PIP     │ │
│  │  (Ruby)    │ │   (PHP)    │ │  (Kotlin)  │ │   (JS)     │ │  (Python)  │ │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘ └────────────┘ │
│  ┌────────────┐ ┌────────────┐                                              │
│  │    SPM     │ │    Yarn    │                                              │
│  │  (Swift)   │ │   (JS)     │                                              │
│  └────────────┘ └────────────┘                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          External Package Registries                         │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ │
│  │ RubyGems   │ │   Maven    │ │    NPM     │ │   PyPI     │ │  GitHub    │ │
│  │    API     │ │    API     │ │  Registry  │ │    API     │ │    API     │ │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘ └────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Output Files                                    │
│  ┌─────────────────────────────┐  ┌─────────────────────────────────────┐   │
│  │     .soup.json              │  │         docs/soup.md                │   │
│  │  (Cache for user choices)   │  │   (Generated SOUP documentation)   │   │
│  └─────────────────────────────┘  └─────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Interactions

1. **CLI Entry Point** (`bin/soup.rb`): Initializes the application and handles top-level error handling
2. **Application** (`lib/soup/application.rb`): Orchestrates the entire workflow from detection to output generation
3. **Options** (`lib/soup/options.rb`): Parses command-line arguments and configures application behavior
4. **Package** (`lib/soup/package.rb`): Data structure representing a third-party dependency with all IEC 62304 required metadata
5. **Parsers** (`lib/soup/parsers/`): Language-specific parsers that read lock files and fetch metadata from package registries; each inherits shared fetching, normalization, and parallelization logic from `SOUP::BaseParser`
6. **Status** (`lib/soup/status.rb`): Defines exit codes for the application
7. **Errors** (`lib/soup/errors.rb`): Defines the `SOUP::Error` exception hierarchy raised throughout the application

## Software units

### SOUP Module

**Purpose:** Root module defining the IEC 62304 risk level constants used throughout the application.

**Location:** `lib/soup.rb`

**Key Components:**

- `RISK_LEVELS_SCREEN`: IEC 62304 risk level definitions (Low, Medium, High)

### SOUP::Application

**Purpose:** Main application class that orchestrates the SOUP documentation workflow.

**Location:** `lib/soup/application.rb`

**Key Components:**

- `PARSER_REGISTRY`: Maps lock file names to parser classes and skip flags
- `initialize(argv)`: Configures options and initializes state
- `execute`: Main entry point that runs the detection, checking, and output workflow. Uses an `ensure` block to persist partial state on failure
- `validate_config!`: Validates that configuration files exist and contain valid JSON
- `detect_packages`: Scans for lock files and invokes appropriate parsers
- `read_cached_packages`: Loads previously entered user choices from cache
- `check_packages`: Validates licenses and prompts for missing IEC 62304 metadata
- `save_files`: Writes cache and markdown documentation files

**Internal Dependencies:**

- `SOUP::Options`
- `SOUP::Package`
- `SOUP::Status`
- `SOUP::Error` hierarchy
- All parser classes

**External Dependencies:**

- `fileutils`
- `json`
- `nokogiri`
- `tty-prompt`

### SOUP::Options

**Purpose:** Command-line argument parsing and configuration management.

**Location:** `lib/soup/options.rb`

**Key Components:**

- `parse`: Parses command-line arguments and returns configured options object
- Configuration attributes: `cache_file`, `markdown_file`, `licenses_file`, `exceptions_file`, `ignored_folders`
- Skip flags: `skip_bundler`, `skip_composer`, `skip_gradle`, `skip_npm`, `skip_pip`, `skip_spm`, `skip_yarn`
- Mode flags: `licenses_check`, `soup_check`, `no_prompt`, `auto_reply`

**External Dependencies:**

- `optparse`

### SOUP::Package

**Purpose:** Data model representing a third-party package with IEC 62304 required metadata.

**Location:** `lib/soup/package.rb`

**Key Components:**

- `self.sanitize_description(text, first_sentence:, strip_markdown:)`: Class method that sanitizes package descriptions by returning nil for nil/empty input, extracting the first sentence, wrapping URLs, and stripping markdown characters
- Attributes: `file`, `language`, `package`, `version`, `license`, `description`, `website`, `last_verified_at`, `risk_level`, `requirements`, `verification_reasoning`, `dependency`
- `verified?`: Returns true when all four verification fields (`last_verified_at`, `risk_level`, `requirements`, `verification_reasoning`) are non-empty
- `as_json`: Serializes package to JSON format
- `to_json`: JSON string representation

### SOUP::Status

**Purpose:** Defines application exit codes.

**Location:** `lib/soup/status.rb`

**Key Components:**

- `SUCCESS_EXIT_CODE`: 0
- `ERROR_EXIT_CODE`: 1

### SOUP::Error Hierarchy

**Purpose:** Defines the structured exception hierarchy raised throughout the application. All errors descend from `SOUP::Error` (a `StandardError`) so the top-level rescue in `bin/soup.rb` catches every soup-internal error.

**Location:** `lib/soup/errors.rb`

**Key Components:**

- `Error`: Base class for all soup-raised errors
- `ConfigurationError`: Missing, unreadable, or malformed configuration file
- `InvalidLockfileError`: Structurally malformed or unsupported lock file
- `UnsupportedFormatError`: Recognized lock file with an unsupported format version (subclass of `InvalidLockfileError`)
- `RegistryError`: Unrecoverable package metadata lookup failure
- `AuthenticationError`: Registry authentication failure (subclass of `RegistryError`)
- `RateLimitError`: Registry rate-limit response (subclass of `RegistryError`)
- `MissingMetadataError`: Required IEC 62304 metadata missing in `--no_prompt` mode or after prompting

### SOUP::HttpClient

**Purpose:** Centralized HTTP GET utility with timeout and retry logic.

**Location:** `lib/soup/http_client.rb`

**Key Components:**

- `DEFAULT_MAX_RETRIES`: Default maximum retry attempts (3); private constant
- `DEFAULT_TIMEOUT_SECONDS`: Default HTTP request timeout in seconds (5); private constant
- `THREAD_COUNT`: Public constant set to `Etc.nprocessors`; used by all parsers as the thread-pool size for parallel metadata fetching
- `self.max_retries`: Returns the retry count, overridable at runtime via the `SOUP_HTTP_MAX_RETRIES` environment variable
- `self.default_timeout`: Returns the request timeout in seconds, overridable at runtime via the `SOUP_HTTP_TIMEOUT` environment variable
- `self.get(url, max_retries: nil, **options)`: Performs HTTP GET with automatic retry on `Net::OpenTimeout` and `Net::ReadTimeout`

**External Dependencies:**

- `etc`
- `httparty`

### SOUP::GenericParser

**Purpose:** Parser delegation wrapper that validates inputs and delegates to specific parsers.

**Location:** `lib/soup/parsers/generic.rb`

**Key Components:**

- `parse(parser, file, packages)`: Validates arguments and delegates to specific parser

### SOUP::BaseParser

**Purpose:** Abstract base class providing the shared logic inherited by every language-specific parser: parallel metadata fetching, package construction, license normalization, and sibling-file resolution.

**Location:** `lib/soup/parsers/base.rb`

**Key Components:**

- `parse(file, packages)`: Abstract method that raises `NotImplementedError` unless overridden by a subclass
- `parallel_each(work_items, packages, &)`: Fetches metadata for the work items concurrently via `Parallel.map(..., in_threads: HttpClient::THREAD_COUNT)` and collects the results
- `collect_packages(results, packages)`: Compacts the fetched results and keys them by package name into the packages hash
- `build_package(...)`: Constructs a `SOUP::Package` with normalized fields
- `normalize_license(license)`: Maps Unlicense and URL-style license values to `NOASSERTION`
- `sibling_file(file, suffix)`: Resolves a sibling manifest path next to a lock file
- `manifest_mentions?(main_file, token)`: Token-boundary test for whether a dependency is declared directly in a source-code manifest; matches only when `token` is not flanked by identifier characters so a name that is a substring of another coordinate (e.g. `androidx.core:core` vs `androidx.core:core-ktx`) is not misclassified. Used by the Gradle and SPM parsers
- `lookup_npm_registry_version(payload, name:, version:)`: Extracts a specific version hash from an npm-style registry payload; shared by the NPM and Yarn parsers
- `http_error_message(response, url:, package:)`: Builds an actionable error message (status code, URL, package, truncated body) for non-2xx responses
- `NOASSERTION_LICENSE`: Public constant for the `NOASSERTION` license value

**External Dependencies:**

- `parallel`

### SOUP::BundlerParser

**Purpose:** Parses Ruby Gemfile.lock files and fetches metadata from RubyGems API.

**Location:** `lib/soup/parsers/bundler.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from RubyGems, fetching metadata for all specs in parallel via the inherited `parallel_each` helper (`BaseParser`)

**External Dependencies:**

- `bundler`
- `parallel`

### SOUP::ComposerParser

**Purpose:** Parses PHP composer.lock files.

**Location:** `lib/soup/parsers/composer.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and extracts package metadata

### SOUP::GradleParser

**Purpose:** Parses Kotlin/Gradle `buildscript-gradle.lockfile` (buildscript classpath) and `gradle.lockfile` (runtime classpath) files, and fetches metadata from Maven repositories.

**Location:** `lib/soup/parsers/gradle.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from Maven Central or fallback repositories, in parallel via the inherited `parallel_each` helper (`BaseParser`). Selects `classpath` entries for `buildscript-gradle.lockfile` and non-test, non-debug `RuntimeClasspath` entries for `gradle.lockfile`
- `REPOSITORY_URLS`: List of Maven repository URLs for fallback lookups

**External Dependencies:**

- `nokogiri`
- `parallel`

### SOUP::NPMParser

**Purpose:** Parses JavaScript package-lock.json files and fetches metadata from NPM registry.

**Location:** `lib/soup/parsers/npm.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from NPM registry in parallel via the inherited `parallel_each` helper (`BaseParser`)

**External Dependencies:**

- `parallel`

### SOUP::PIPParser

**Purpose:** Parses Python requirements.txt files and fetches metadata from PyPI.

**Location:** `lib/soup/parsers/pip.rb`

**Key Components:**

- `parse(file, packages)`: Parses requirements file and fetches package details from PyPI in parallel via the inherited `parallel_each` helper (`BaseParser`)

**External Dependencies:**

- `parallel`

### SOUP::SPMParser

**Purpose:** Parses Swift Package Manager Package.resolved files and fetches metadata from GitHub API.

**Location:** `lib/soup/parsers/spm.rb`

**Key Components:**

- `parse(file, packages)`: Parses resolved file and fetches package details from GitHub API in parallel via the inherited `parallel_each` helper (`BaseParser`)
- Resolves the direct-dependency manifest for `Package.resolved` files that are nested inside an Xcode project bundle by trying, in order, a sibling `Package.swift` (or matching `<Name>.swift`), an enclosing `Tuist/Dependencies.swift` when the resolved file lives under a Tuist directory, a sibling `<Name>.xcodeproj/project.pbxproj`, and finally the `project.pbxproj` of an enclosing `*.xcodeproj` higher up the tree; the resolved manifest is passed to `manifest_mentions?` to classify direct vs transitive dependencies
- Supports `GITHUB_TOKEN` environment variable for rate limit handling

**External Dependencies:**

- `parallel`

### SOUP::YarnParser

**Purpose:** Parses JavaScript yarn.lock files and fetches metadata from NPM registry.

**Location:** `lib/soup/parsers/yarn.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from NPM registry in parallel via the inherited `parallel_each` helper (`BaseParser`)

**External Dependencies:**

- `parallel`
- `yarn_lock_parser`

## Software of Unknown Provenance

See [soup.md](soup.md) for the complete list of third-party dependencies. The `soup.md` file is auto-generated by the `soup` tool itself; never edit it directly. All metadata is sourced from `.soup.json` (cache) and the lock files at the project root.

### Risk Level Classification (per IEC 62304)

| Level | Definition |
| :--- | :--- |
| Low | Cannot lead to harm |
| Medium | Can lead to reversible harm |
| High | Can lead to irreversible harm |

### Requirements

Explains why this library is needed. Examples:

- "HTTP client for REST API access"
- "Command-line argument parsing"
- "XML parsing"
- "Dependency" — used when the package is only present transitively, not directly required

### Verification Reasoning

Explains why this specific library was chosen over alternatives. Examples:

- "Industry standard with active maintenance"
- "Official SDK provided by vendor"
- "Most popular library on rubygems.org"
- "Dependency" — used when the package is only present transitively, not directly required

### Validation

All packages are validated against:

- Authorized license list (`config/licenses.json`)
- Package-specific exceptions (`config/exceptions.json`)

Validation criteria for SOUP entries: Accuracy (Requirements match actual usage), Completeness (all lock-file packages present in `.soup.json`), Staleness (removed packages absent), Risk Level (appropriate for the package's function).

## Critical algorithms

### Package Detection Algorithm

**Purpose:** Recursively scans the project directory for supported lock files.

**Location:** `lib/soup/application.rb` in `detect_packages` method

**Implementation:**

1. Iterates through known package manager lock file names
2. Uses glob pattern to find matching files recursively
3. Excludes `node_modules/` and `vendor/` directories
4. Excludes user-specified ignored folders
5. Delegates to appropriate parser based on file name

**Complexity:** O(n) where n is the number of files in the project

### License Validation Algorithm

**Purpose:** Validates that all dependencies use approved open-source licenses.

**Location:** `lib/soup/application.rb` in `validate_license` method (invoked from `check_packages`)

**Implementation:**

1. Loads authorized licenses from configuration file
2. Loads package-specific exceptions from configuration file
3. For each detected package with a license:
   - Checks if license contains any authorized license substring (case-insensitive)
   - Checks if package is in exceptions list
   - Reports error if license is not approved and not `NOASSERTION`

### Direct vs Transitive Dependency Classification Algorithm

**Purpose:** Classifies each detected package as a direct dependency (declared in the project's manifest) or a transitive dependency (pulled in only by other packages), recorded in `SOUP::Package#dependency`.

**Location:** Per-parser, using helpers in `lib/soup/parsers/base.rb` (`SOUP::BaseParser`)

**Implementation:**

1. For parsers whose manifest is structured data that can be parsed into an exact dependency set (Bundler, Composer, NPM, PIP, Yarn), the direct dependency names are read from the manifest (e.g. `Gemfile` dependencies, the sibling `requirements.in`) and matched against package names with an exact-name comparison
2. For parsers whose manifest is source code that cannot be parsed into an exact set (Gradle build scripts, Swift `Package.swift`/`pbxproj`), `manifest_mentions?(main_file, token)` performs a token-boundary regex match so a name that is a substring of another coordinate is not misclassified
3. A package is marked transitive (`dependency: true`) when it is not found among the direct dependencies

### Markdown Sanitization Algorithm

**Purpose:** Sanitizes package descriptions for safe markdown table inclusion.

**Location:** `lib/soup/application.rb` in `markdown_cell` method

**Implementation:**

1. Returns a single space for nil/empty values
2. Collapses any whitespace run (including embedded newlines and tabs) to a single space so a multi-line package description does not break the markdown table
3. Fixes MD038 lint rule violations (spaces inside backtick code spans)
4. Uses regex pattern ``[^`]*`` instead of ``\s*(.*?)\s*`` to avoid ReDoS vulnerability

### HTTP Retry Algorithm

**Purpose:** Handles transient network failures when fetching package metadata.

**Location:** `lib/soup/http_client.rb` in `SOUP::HttpClient.get` method

**Implementation:**

1. Attempts HTTP GET request with the configured timeout (`DEFAULT_TIMEOUT_SECONDS`, 5 seconds by default; overridable via `SOUP_HTTP_TIMEOUT`)
2. On `Net::OpenTimeout` or `Net::ReadTimeout`:
   - Increments retry counter
   - Logs retry attempt with counter
   - Retries up to the configured maximum (`DEFAULT_MAX_RETRIES`, 3 by default; overridable via `SOUP_HTTP_MAX_RETRIES`)
   - Raises the exception after max retries are exhausted

### Parallel Metadata Fetching Algorithm

**Purpose:** Speeds up registry lookups by fetching package metadata concurrently instead of serially.

**Location:** `parallel_each` in `lib/soup/parsers/base.rb` (`SOUP::BaseParser`), invoked from the `parse` method of the Bundler, Gradle, NPM, PIP, SPM, and Yarn parsers

**Implementation:**

1. Builds a work-item list of packages discovered in the lock file
2. Processes the list with `Parallel.map(work_items, in_threads: HttpClient::THREAD_COUNT)` inside `BaseParser#parallel_each`
3. `THREAD_COUNT` is `Etc.nprocessors`, sizing the thread pool to the available CPU cores
4. Each thread fetches metadata through `SOUP::HttpClient.get` (which applies its own timeout and retry logic)

## Risk controls

### Input Validation

| Control | Implementation | Location |
| :--- | :--- | :--- |
| Parser argument validation | Type checking for parser, file path, and packages hash | `lib/soup/parsers/generic.rb` in `parse` method |
| Package name validation | Raises error if package name is nil | `lib/soup/package.rb` in `initialize` method |
| File path validation | Checks file existence before reading | Throughout parsers |
| Command-line option validation | Uses OptionParser with defined option types | `lib/soup/options.rb` |

### Error Handling

Recoverable failures raise a subclass of `SOUP::Error` (`lib/soup/errors.rb`); the top-level rescue in `bin/soup.rb` catches them and reports a message.

| Failure Mode | Handling | Location |
| :--- | :--- | :--- |
| Invalid command-line options | Catches `OptionParser::ParseError`, displays error, exits with error code | `lib/soup/application.rb` in `configure_options` method |
| Missing or malformed config file | Raises `ConfigurationError` when a configuration file is absent or contains invalid JSON | `lib/soup/application.rb` in `validate_config!` method |
| API rate limiting | Raises `RateLimitError` (and `AuthenticationError` for bad credentials), suggesting `GITHUB_TOKEN` | `lib/soup/parsers/spm.rb` in `parse` method |
| Network timeouts | Retry up to 3 times via `SOUP::HttpClient` | `lib/soup/http_client.rb` in `get` method |
| Missing package metadata | Logs warning and continues processing other packages | NPM, Gradle parsers |
| Missing required IEC 62304 fields | Raises `MissingMetadataError` in `--no_prompt` mode, prompts user otherwise | `lib/soup/application.rb` in `prompt_missing_field` / `ensure_metadata_complete!` methods |
| Partial execution failure | Persists partial state via `ensure` block so progress is not lost | `lib/soup/application.rb` in `execute` method |
| Unhandled exceptions | Displays error message and the top frames of the backtrace; full backtrace shown only when `ENV['DEBUG']` is set | `bin/soup.rb` top-level rescue |

### Security Controls

| Control | Description | Implementation |
| :--- | :--- | :--- |
| ReDoS prevention | Uses non-backtracking regex pattern for markdown sanitization | `lib/soup/application.rb` in `markdown_cell` method |
| HTML entity sanitization | Uses Nokogiri to decode HTML entities in descriptions | `lib/soup/application.rb` in `sanitize_markdown_description` method |
| License compliance | Validates all dependencies against approved license list | `lib/soup/application.rb` in `validate_license` method |
| Directory traversal prevention | Excludes `node_modules/` and `vendor/` from scanning | `lib/soup/application.rb` in `detect_packages` method |
| API token handling | Uses environment variable for GitHub token, never logged | `lib/soup/parsers/spm.rb` in `parse` method |

### Operational Controls

| Control | Description |
| :--- | :--- |
| Exit codes | Defined exit codes for success (0) and error (1) |
| Cache persistence | User-entered metadata cached in `.soup.json` to avoid re-entry |
| CI/CD mode | `--no_prompt` flag for non-interactive execution |
| Selective parsing | Skip flags allow excluding specific package managers |
| Folder exclusion | `--ignored_folders` allows excluding directories from scanning |
