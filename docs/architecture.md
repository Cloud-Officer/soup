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
│  │ RubyGems   │ │  Packagist │ │   Maven    │ │    NPM     │ │   PyPI     │ │
│  │    API     │ │    API     │ │    API     │ │  Registry  │ │    API     │ │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘ └────────────┘ │
│  ┌────────────┐                                                             │
│  │  GitHub    │                                                             │
│  │    API     │                                                             │
│  └────────────┘                                                             │
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

**Purpose:** Root module defining constants and configuration for supported package managers and risk levels.

**Location:** `lib/soup.rb`

**Key Components:**

- `PACKAGE_MANAGERS`: List of supported lock file names
- `RISK_LEVELS_SCREEN`: IEC 62304 risk level definitions (Low, Medium, High)

### SOUP::Application

**Purpose:** Main application class that orchestrates the SOUP documentation workflow.

**Location:** `lib/soup/application.rb`

**Key Components:**

- `initialize(argv)`: Configures options and initializes state
- `execute`: Main entry point that runs the detection, checking, and output workflow
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
- `inquirer`
- `json`
- `nokogiri`
- `tty-prompt`

### SOUP::Options

**Purpose:** Command-line argument parsing and configuration management.

**Location:** `lib/soup/options.rb`

**Key Components:**

- `parse`: Parses command-line arguments and returns configured options object
- Configuration attributes: `cache_file`, `markdown_file`, `licenses_file`, `exceptions_file`
- Skip flags: `skip_bundler`, `skip_composer`, `skip_gradle`, `skip_npm`, `skip_pip`, `skip_spm`, `skip_yarn`, `skip_cocoapods`
- Mode flags: `licenses_check`, `soup_check`, `no_prompt`, `auto_reply`

**External Dependencies:**

- `optparse`

### SOUP::Package

**Purpose:** Data model representing a third-party package with IEC 62304 required metadata.

**Location:** `lib/soup/package.rb`

**Key Components:**

- Attributes: `language`, `package`, `version`, `license`, `description`, `website`, `last_verified_at`, `risk_level`, `requirements`, `verification_reasoning`, `dependency`
- `as_json`: Serializes package to JSON format
- `to_json`: JSON string representation

### SOUP::Status

**Purpose:** Defines application exit codes.

**Location:** `lib/soup/status.rb`

**Key Components:**

- `SUCCESS_EXIT_CODE`: 0
- `ERROR_EXIT_CODE`: 1
- `FAILURE_EXIT_CODE`: 2

### SOUP::GenericParser

**Purpose:** Base parser class that validates inputs and delegates to specific parsers.

**Location:** `lib/soup/parsers/generic.rb`

**Key Components:**

- `parse(parser, file, packages)`: Validates arguments and delegates to specific parser

### SOUP::BundlerParser

**Purpose:** Parses Ruby Gemfile.lock files and fetches metadata from RubyGems API.

**Location:** `lib/soup/parsers/bundler.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from RubyGems

**External Dependencies:**

- `bundler`
- `httparty`

### SOUP::ComposerParser

**Purpose:** Parses PHP composer.lock files.

**Location:** `lib/soup/parsers/composer.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and extracts package metadata

### SOUP::GradleParser

**Purpose:** Parses Kotlin/Gradle buildscript-gradle.lockfile and fetches metadata from Maven repositories.

**Location:** `lib/soup/parsers/gradle.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from Maven Central or fallback repositories
- `REPOSITORY_URLS`: List of Maven repository URLs for fallback lookups

**External Dependencies:**

- `httparty`
- `nokogiri`

### SOUP::NPMParser

**Purpose:** Parses JavaScript package-lock.json files and fetches metadata from NPM registry.

**Location:** `lib/soup/parsers/npm.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from NPM registry
- `MAX_RETRIES`: Retry limit for network timeouts

**External Dependencies:**

- `httparty`

### SOUP::PIPParser

**Purpose:** Parses Python requirements.txt files and fetches metadata from PyPI.

**Location:** `lib/soup/parsers/pip.rb`

**Key Components:**

- `parse(file, packages)`: Parses requirements file and fetches package details from PyPI
- `RequestWithTimeoutAndRetries`: Helper class for HTTP requests with timeout handling

**External Dependencies:**

- `httparty`

### SOUP::SPMParser

**Purpose:** Parses Swift Package Manager Package.resolved files and fetches metadata from GitHub API.

**Location:** `lib/soup/parsers/spm.rb`

**Key Components:**

- `parse(file, packages)`: Parses resolved file and fetches package details from GitHub API
- Supports `GITHUB_TOKEN` environment variable for rate limit handling

**External Dependencies:**

- `httparty`

### SOUP::YarnParser

**Purpose:** Parses JavaScript yarn.lock files and fetches metadata from NPM registry.

**Location:** `lib/soup/parsers/yarn.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from NPM registry
- `MAX_RETRIES`: Retry limit for network timeouts

**External Dependencies:**

- `yarn_lock_parser`
- `httparty`

## Software of Unknown Provenance

| Package | Version | License | Purpose |
| :--- | :---: | :---: | :--- |
| activesupport | 8.1.2 | MIT | Dependency of other gems |
| ast | 2.4.3 | MIT | Dependency of rubocop |
| base64 | 0.3.0 | Ruby | Dependency |
| bigdecimal | 4.0.1 | Ruby | Dependency |
| concurrent-ruby | 1.3.6 | MIT | Dependency of activesupport |
| connection_pool | 3.0.2 | MIT | Dependency |
| csv | 3.3.5 | Ruby | Dependency of httparty |
| drb | 2.2.3 | Ruby | Dependency |
| httparty | 0.24.2 | MIT | HTTP client for API requests to package registries |
| i18n | 1.14.8 | MIT | Dependency of activesupport |
| inquirer | 0.2.1 | Apache-2.0 | Interactive CLI prompts for user input |
| io-console | 0.8.2 | Ruby | Dependency |
| json | 2.18.0 | Ruby | JSON parsing for lock files and cache |
| language_server-protocol | 3.17.0.5 | MIT | Dependency of rubocop |
| lint_roller | 1.1.0 | MIT | Dependency of rubocop plugins |
| logger | 1.7.0 | Ruby | Dependency |
| mini_mime | 1.1.5 | MIT | Dependency of httparty |
| minitest | 6.0.1 | MIT | Dependency |
| mize | 0.6.1 | MIT | Dependency |
| multi_xml | 0.8.1 | MIT | Dependency of httparty |
| nokogiri | 1.19.0 | MIT | XML/HTML parsing for Gradle POM files and description sanitization |
| optparse | 0.8.1 | Ruby | Command-line argument parsing |
| parallel | 1.27.0 | MIT | Dependency of rubocop |
| parser | 3.3.10.1 | MIT | Dependency of rubocop |
| pastel | 0.8.0 | MIT | Dependency of tty-prompt |
| prism | 1.8.0 | MIT | Dependency |
| racc | 1.8.1 | Ruby | Dependency of nokogiri |
| rainbow | 3.1.1 | MIT | Dependency of rubocop |
| readline | 0.0.4 | Ruby | Dependency |
| regexp_parser | 2.11.3 | MIT | Dependency of rubocop |
| reline | 0.6.3 | Ruby | Dependency |
| rubocop | 1.82.1 | MIT | Development dependency for code linting |
| rubocop-ast | 1.49.0 | MIT | Dependency of rubocop |
| rubocop-capybara | 2.22.1 | MIT | Development dependency for linting |
| rubocop-graphql | 1.5.6 | MIT | Development dependency for linting |
| rubocop-minitest | 0.38.2 | MIT | Development dependency for linting |
| rubocop-performance | 1.26.1 | MIT | Development dependency for linting |
| rubocop-rspec | 3.9.0 | MIT | Development dependency for linting |
| rubocop-thread_safety | 0.7.3 | MIT | Development dependency for linting |
| ruby-progressbar | 1.13.0 | MIT | Dependency of rubocop |
| securerandom | 0.4.1 | Ruby | Dependency |
| semantic | 1.6.1 | MIT | Semantic version parsing and comparison |
| sync | 0.5.0 | BSD-2-Clause | Dependency |
| term-ansicolor | 1.11.3 | Apache-2.0 | Dependency of inquirer |
| tins | 1.51.1 | MIT | Dependency |
| tty-color | 0.6.0 | MIT | Dependency of tty-prompt |
| tty-cursor | 0.7.1 | MIT | Dependency of tty-prompt |
| tty-prompt | 0.23.1 | MIT | Interactive CLI prompts for risk level and requirements input |
| tty-reader | 0.9.0 | MIT | Dependency of tty-prompt |
| tty-screen | 0.8.2 | MIT | Dependency of tty-prompt |
| tzinfo | 2.0.6 | MIT | Dependency of activesupport |
| unicode-display_width | 3.2.0 | MIT | Dependency of rubocop |
| unicode-emoji | 4.2.0 | MIT | Dependency |
| uri | 1.1.1 | Ruby | Dependency |
| wisper | 2.0.1 | MIT | Dependency of tty-reader |
| yarn_lock_parser | 0.1.0 | MIT | Parsing yarn.lock files |

### Critical Dependencies

| Package | Purpose | Risk Assessment |
| :--- | :--- | :--- |
| httparty | HTTP client for all external API calls | Low - widely used, MIT licensed |
| nokogiri | XML parsing for Maven POM files | Low - industry standard, MIT licensed |
| bundler | Ruby Gemfile.lock parsing | Low - Ruby standard tool |
| json | JSON parsing for lock files and cache | Low - Ruby standard library |
| tty-prompt | User interaction for IEC 62304 metadata | Low - no security implications |

## Critical algorithms

### Package Detection Algorithm

**Purpose:** Recursively scans the project directory for supported lock files.

**Location:** `lib/soup/application.rb:61-125`

**Implementation:**

1. Iterates through known package manager lock file names
2. Uses glob pattern to find matching files recursively
3. Excludes `node_modules/` and `vendor/` directories
4. Excludes user-specified ignored folders
5. Delegates to appropriate parser based on file name

**Complexity:** O(n) where n is the number of files in the project

### License Validation Algorithm

**Purpose:** Validates that all dependencies use approved open-source licenses.

**Location:** `lib/soup/application.rb:140-162`

**Implementation:**

1. Loads authorized licenses from configuration file
2. Loads package-specific exceptions from configuration file
3. For each detected package with a license:
   - Checks if license contains any authorized license substring (case-insensitive)
   - Checks if package is in exceptions list
   - Reports error if license is not approved and not `NOASSERTION`

### Markdown Sanitization Algorithm

**Purpose:** Sanitizes package descriptions for safe markdown table inclusion.

**Location:** `lib/soup/application.rb:45-51`

**Implementation:**

1. Strips leading/trailing whitespace
2. Fixes MD038 lint rule violations (spaces inside backtick code spans)
3. Uses regex pattern `[^`]* instead of `\s*(.*?)\s*` to avoid ReDoS vulnerability

### HTTP Retry Algorithm

**Purpose:** Handles transient network failures when fetching package metadata.

**Location:** `lib/soup/parsers/pip.rb:61-77`, `lib/soup/parsers/npm.rb:23-37`, `lib/soup/parsers/yarn.rb:23-37`

**Implementation:**

1. Attempts HTTP request
2. On `Net::OpenTimeout` or `Net::ReadTimeout`:
   - Increments retry counter
   - Retries up to `MAX_RETRIES` (3) times
   - Aborts and continues to next package after max retries

## Risk controls

### Input Validation

| Control | Implementation | Location |
| :--- | :--- | :--- |
| Parser argument validation | Type checking for parser, file path, and packages hash | `lib/soup/parsers/generic.rb:5-14` |
| Package name validation | Raises error if package name is nil | `lib/soup/package.rb:6` |
| File path validation | Checks file existence before reading | Throughout parsers |
| Command-line option validation | Uses OptionParser with defined option types | `lib/soup/options.rb` |

### Error Handling

| Failure Mode | Handling | Location |
| :--- | :--- | :--- |
| Invalid command-line options | Catches `OptionParser::InvalidOption`, displays error, exits with error code | `lib/soup/application.rb:56-59` |
| API rate limiting | Detects rate limit messages, suggests setting `GITHUB_TOKEN` | `lib/soup/parsers/spm.rb:45` |
| Network timeouts | Retry with exponential backoff up to 3 times | Multiple parsers |
| Missing package metadata | Logs warning and continues processing other packages | NPM, Gradle parsers |
| Missing required IEC 62304 fields | Raises error in `--no_prompt` mode, prompts user otherwise | `lib/soup/application.rb:179-209` |

### Security Controls

| Control | Description | Implementation |
| :--- | :--- | :--- |
| ReDoS prevention | Uses non-backtracking regex pattern for markdown sanitization | `lib/soup/application.rb:49-50` |
| HTML entity sanitization | Uses Nokogiri to decode HTML entities in descriptions | `lib/soup/application.rb:216` |
| License compliance | Validates all dependencies against approved license list | `lib/soup/application.rb:146-161` |
| Directory traversal prevention | Excludes `node_modules/` and `vendor/` from scanning | `lib/soup/application.rb:66-68` |
| API token handling | Uses environment variable for GitHub token, never logged | `lib/soup/parsers/spm.rb:24-31` |

### Operational Controls

| Control | Description |
| :--- | :--- |
| Exit codes | Defined exit codes for success (0), error (1), and failure (2) |
| Cache persistence | User-entered metadata cached in `.soup.json` to avoid re-entry |
| CI/CD mode | `--no_prompt` flag for non-interactive execution |
| Selective parsing | Skip flags allow excluding specific package managers |
| Folder exclusion | `--ignored_folders` allows excluding directories from scanning |
