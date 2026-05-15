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
│  ┌────────────┐ ┌────────────┐ ┌────────────┐                               │
│  │    SPM     │ │    Yarn    │ │  CocoaPods │                               │
│  │  (Swift)   │ │   (JS)     │ │  (Swift)*  │  * Currently disabled         │
│  └────────────┘ └────────────┘ └────────────┘                               │
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
5. **Parsers** (`lib/soup/parsers/`): Language-specific parsers that read lock files and fetch metadata from package registries
6. **Status** (`lib/soup/status.rb`): Defines exit codes for the application

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
- Skip flags: `skip_bundler`, `skip_cocoapods`, `skip_composer`, `skip_gradle`, `skip_npm`, `skip_pip`, `skip_spm`, `skip_yarn`
- Mode flags: `licenses_check`, `soup_check`, `no_prompt`, `auto_reply`

**External Dependencies:**

- `optparse`

### SOUP::Package

**Purpose:** Data model representing a third-party package with IEC 62304 required metadata.

**Location:** `lib/soup/package.rb`

**Key Components:**

- `self.sanitize_description(text, first_sentence:, strip_markdown:)`: Class method that sanitizes package descriptions by returning nil for nil/empty input, extracting the first sentence, wrapping URLs, and stripping markdown characters
- Attributes: `file`, `language`, `package`, `version`, `license`, `description`, `website`, `last_verified_at`, `risk_level`, `requirements`, `verification_reasoning`, `dependency`
- `as_json`: Serializes package to JSON format
- `to_json`: JSON string representation

### SOUP::Status

**Purpose:** Defines application exit codes.

**Location:** `lib/soup/status.rb`

**Key Components:**

- `SUCCESS_EXIT_CODE`: 0
- `ERROR_EXIT_CODE`: 1
- `FAILURE_EXIT_CODE`: 2

### SOUP::HttpClient

**Purpose:** Centralized HTTP GET utility with timeout and retry logic.

**Location:** `lib/soup/http_client.rb`

**Key Components:**

- `MAX_RETRIES`: Maximum retry attempts (3)
- `DEFAULT_TIMEOUT`: HTTP request timeout in seconds (5)
- `THREAD_COUNT`: Public constant set to `Etc.nprocessors`; used by all parsers as the thread-pool size for parallel metadata fetching
- `self.get(url, max_retries:, **options)`: Performs HTTP GET with automatic retry on `Net::OpenTimeout` and `Net::ReadTimeout`

**External Dependencies:**

- `etc`
- `httparty`

### SOUP::GenericParser

**Purpose:** Parser delegation wrapper that validates inputs and delegates to specific parsers.

**Location:** `lib/soup/parsers/generic.rb`

**Key Components:**

- `parse(parser, file, packages)`: Validates arguments and delegates to specific parser

### SOUP::BundlerParser

**Purpose:** Parses Ruby Gemfile.lock files and fetches metadata from RubyGems API.

**Location:** `lib/soup/parsers/bundler.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from RubyGems, fetching metadata for all specs in parallel via `Parallel.map(..., in_threads: HttpClient::THREAD_COUNT)`

**External Dependencies:**

- `bundler`
- `parallel`

### SOUP::CocoaPodsParser

**Purpose:** Parses Swift Podfile.lock files and fetches metadata from the local CocoaPods trunk repository. Currently disabled because cocoapods-core requires activesupport < 8.

**Location:** `lib/soup/parsers/cocoapods.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file, resolves specifications from local trunk source, and extracts package metadata

**External Dependencies:**

- `active_support`
- `cocoapods-core` (conditionally loaded on macOS only)
- `semantic`

### SOUP::ComposerParser

**Purpose:** Parses PHP composer.lock files.

**Location:** `lib/soup/parsers/composer.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and extracts package metadata

### SOUP::GradleParser

**Purpose:** Parses Kotlin/Gradle `buildscript-gradle.lockfile` (buildscript classpath) and `gradle.lockfile` (runtime classpath) files, and fetches metadata from Maven repositories.

**Location:** `lib/soup/parsers/gradle.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from Maven Central or fallback repositories, in parallel via `Parallel.map(..., in_threads: HttpClient::THREAD_COUNT)`. Selects `classpath` entries for `buildscript-gradle.lockfile` and non-test, non-debug `RuntimeClasspath` entries for `gradle.lockfile`
- `REPOSITORY_URLS`: List of Maven repository URLs for fallback lookups

**External Dependencies:**

- `nokogiri`
- `parallel`

### SOUP::NPMParser

**Purpose:** Parses JavaScript package-lock.json files and fetches metadata from NPM registry.

**Location:** `lib/soup/parsers/npm.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from NPM registry in parallel via `Parallel.map(..., in_threads: HttpClient::THREAD_COUNT)`

**External Dependencies:**

- `parallel`

### SOUP::PIPParser

**Purpose:** Parses Python requirements.txt files and fetches metadata from PyPI.

**Location:** `lib/soup/parsers/pip.rb`

**Key Components:**

- `parse(file, packages)`: Parses requirements file and fetches package details from PyPI in parallel via `Parallel.map(..., in_threads: HttpClient::THREAD_COUNT)`

**External Dependencies:**

- `parallel`

### SOUP::SPMParser

**Purpose:** Parses Swift Package Manager Package.resolved files and fetches metadata from GitHub API.

**Location:** `lib/soup/parsers/spm.rb`

**Key Components:**

- `parse(file, packages)`: Parses resolved file and fetches package details from GitHub API in parallel via `Parallel.map(..., in_threads: HttpClient::THREAD_COUNT)`
- Supports `GITHUB_TOKEN` environment variable for rate limit handling

**External Dependencies:**

- `parallel`

### SOUP::YarnParser

**Purpose:** Parses JavaScript yarn.lock files and fetches metadata from NPM registry.

**Location:** `lib/soup/parsers/yarn.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from NPM registry in parallel via `Parallel.map(..., in_threads: HttpClient::THREAD_COUNT)`

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

**Location:** `lib/soup/application.rb` in `check_packages` method

**Implementation:**

1. Loads authorized licenses from configuration file
2. Loads package-specific exceptions from configuration file
3. For each detected package with a license:
   - Checks if license contains any authorized license substring (case-insensitive)
   - Checks if package is in exceptions list
   - Reports error if license is not approved and not `NOASSERTION`

### Markdown Sanitization Algorithm

**Purpose:** Sanitizes package descriptions for safe markdown table inclusion.

**Location:** `lib/soup/application.rb` in `markdown_cell` method

**Implementation:**

1. Strips leading/trailing whitespace
2. Fixes MD038 lint rule violations (spaces inside backtick code spans)
3. Uses regex pattern ``[^`]*`` instead of ``\s*(.*?)\s*`` to avoid ReDoS vulnerability

### HTTP Retry Algorithm

**Purpose:** Handles transient network failures when fetching package metadata.

**Location:** `lib/soup/http_client.rb` in `SOUP::HttpClient.get` method

**Implementation:**

1. Attempts HTTP GET request with `DEFAULT_TIMEOUT` (5 seconds)
2. On `Net::OpenTimeout` or `Net::ReadTimeout`:
   - Increments retry counter
   - Logs retry attempt with counter
   - Retries up to `MAX_RETRIES` (3) times
   - Raises the exception after max retries are exhausted

### Parallel Metadata Fetching Algorithm

**Purpose:** Speeds up registry lookups by fetching package metadata concurrently instead of serially.

**Location:** `parse` method of the Bundler, Gradle, NPM, PIP, SPM, and Yarn parsers in `lib/soup/parsers/`

**Implementation:**

1. Builds a work-item list of packages discovered in the lock file
2. Processes the list with `Parallel.map(work_items, in_threads: HttpClient::THREAD_COUNT)`
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

| Failure Mode | Handling | Location |
| :--- | :--- | :--- |
| Invalid command-line options | Catches `OptionParser::InvalidOption`, displays error, exits with error code | `lib/soup/application.rb` in `configure_options` method |
| API rate limiting | Detects rate limit messages, suggests setting `GITHUB_TOKEN` | `lib/soup/parsers/spm.rb` in `parse` method |
| Network timeouts | Retry up to 3 times via `SOUP::HttpClient` | `lib/soup/http_client.rb` in `get` method |
| Missing package metadata | Logs warning and continues processing other packages | NPM, Gradle parsers |
| Missing required IEC 62304 fields | Raises error in `--no_prompt` mode, prompts user otherwise | `lib/soup/application.rb` in `check_packages` method |
| Partial execution failure | Persists partial state via `ensure` block so progress is not lost | `lib/soup/application.rb` in `execute` method |
| Unhandled exceptions | Displays error message; backtrace only shown when `ENV['DEBUG']` is set | `bin/soup.rb` top-level rescue |

### Security Controls

| Control | Description | Implementation |
| :--- | :--- | :--- |
| ReDoS prevention | Uses non-backtracking regex pattern for markdown sanitization | `lib/soup/application.rb` in `markdown_cell` method |
| HTML entity sanitization | Uses Nokogiri to decode HTML entities in descriptions | `lib/soup/application.rb` in `check_packages` method |
| License compliance | Validates all dependencies against approved license list | `lib/soup/application.rb` in `check_packages` method |
| Directory traversal prevention | Excludes `node_modules/` and `vendor/` from scanning | `lib/soup/application.rb` in `detect_packages` method |
| API token handling | Uses environment variable for GitHub token, never logged | `lib/soup/parsers/spm.rb` in `parse` method |

### Operational Controls

| Control | Description |
| :--- | :--- |
| Exit codes | Defined exit codes for success (0), error (1), and failure (2) |
| Cache persistence | User-entered metadata cached in `.soup.json` to avoid re-entry |
| CI/CD mode | `--no_prompt` flag for non-interactive execution |
| Selective parsing | Skip flags allow excluding specific package managers |
| Folder exclusion | `--ignored_folders` allows excluding directories from scanning |
