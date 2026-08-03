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
│                              CLI Entry Point                                │
│                              bin/soup.rb                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                             SOUP::Application                               │
│                          lib/soup/application.rb                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │   detect    │  │    read     │  │    check    │  │       save          │ │
│  │  packages   │──│   cached    │──│  packages   │──│      files          │ │
│  │             │  │  packages   │  │             │  │                     │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
         │                                   │
         ▼                                   ▼
┌─────────────────────────┐    ┌──────────────────────────────────────────────┐
│    SOUP::Options        │    │              SOUP::Package                   │
│  lib/soup/options.rb    │    │           lib/soup/package.rb                │
│                         │    │                                              │
│  Command-line parsing   │    │  Data model for package information          │
└─────────────────────────┘    └──────────────────────────────────────────────┘

              Application#detect_packages → SOUP::GenericParser
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Package Manager Parsers                           │
│                           lib/soup/parsers/                                 │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ │
│  │  Bundler   │ │  Composer  │ │   Gradle   │ │    NPM     │ │    PIP     │ │
│  │  (Ruby)    │ │   (PHP)    │ │  (Kotlin)  │ │   (JS)     │ │  (Python)  │ │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘ └────────────┘ │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐                │
│  │    SPM     │ │    Yarn    │ │ Importmap  │ │   Manual   │                │
│  │  (Swift)   │ │   (JS)     │ │  (Rails)   │ │ (vendored) │                │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘                │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                             SOUP::HttpClient                                │
│                          lib/soup/http_client.rb                            │
│        Shared timeout, retry, and Etc.nprocessors thread-pool sizing        │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          External Package Registries                        │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ │
│  │ RubyGems   │ │   Maven    │ │    NPM     │ │   PyPI     │ │  GitHub    │ │
│  │    API     │ │    API     │ │  Registry  │ │    API     │ │    API     │ │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘ └────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Output Files                                   │
│  ┌─────────────────────────────┐  ┌─────────────────────────────────────┐   │
│  │     .soup.json              │  │         docs/soup.md                │   │
│  │  (Cache for user choices)   │  │   (Generated SOUP documentation)    │   │
│  └─────────────────────────────┘  └─────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Interactions

1. **CLI Entry Point** (`bin/soup.rb`): Initializes the application and handles top-level error handling
2. **Application** (`lib/soup/application.rb`): Orchestrates the entire workflow from detection to output generation
3. **Options** (`lib/soup/options.rb`): Parses command-line arguments and configures application behavior
4. **Package** (`lib/soup/package.rb`): Data structure representing a third-party dependency with all IEC 62304 required metadata
5. **Parsers** (`lib/soup/parsers/`): Language-specific parsers that read lock files and fetch metadata from package registries; each inherits shared fetching, normalization, and parallelization logic from `SOUP::BaseParser`. The `ImportmapParser` resolves CDN-pinned dependencies from a Rails `config/importmap.rb`, and the `ManualParser` reads manually-declared entries for vendored/proprietary components that no registry can resolve
6. **HttpClient** (`lib/soup/http_client.rb`): Single HTTP entry point used by every parser; applies the shared timeout, retry, and thread-pool sizing
7. **Status** (`lib/soup/status.rb`): Defines exit codes for the application
8. **Errors** (`lib/soup/errors.rb`): Defines the `SOUP::Error` exception hierarchy raised throughout the application

## Software units

### SOUP Module

**Purpose:** Root module defining the IEC 62304 risk level constants used throughout the application.

**Location:** `lib/soup.rb`

**Key Components:**

- `RISK_LEVELS_SCREEN`: Private constant holding the IEC 62304 risk level prompt choices (Low, Medium, High); the first entry is the default applied to transitive dependencies and by `--auto_reply`

### SOUP::Application

**Purpose:** Main application class that orchestrates the SOUP documentation workflow.

**Location:** `lib/soup/application.rb`

**Key Components:**

- `PARSER_REGISTRY`: Private module-level constant (`module SOUP`) mapping lock file names to parser classes and skip flags
- `DEPENDENCY_TEXT`: Private module-level constant (`module SOUP`) holding the value written into `requirements` and `verification_reasoning` for transitive dependencies
- `initialize(argv)`: Configures options and initializes state
- `execute`: Main entry point that runs the detection, checking, and output workflow. On success it calls `save_files` and marks the run complete; if it raises, the `ensure` block routes to `save_partial_state` instead, so a failed run can never take the full-overwrite path
- `validate_config!`: Validates that `--licenses_file` and `--exceptions_file` exist and contain valid JSON (via `validate_json!`), then delegates to `validate_cache_file!`
- `validate_cache_file!`: Validates the cache file's JSON before any state exists, and only when `--soup` will actually read it (the cache is legitimately absent on a first run). Deliberately runs here rather than in `read_cached_packages`: a parse error raised there would escape through the `ensure` block save, rewriting `.soup.json` with metadata-less entries and blanking `docs/soup.md`. Failing this early lets `save_files`' empty-state guard leave both files untouched
- `detect_packages`: Scans for lock files and invokes appropriate parsers, then runs `parse_manual_entries` and `enforce_vendored_coverage`
- `parse_manual_entries`: Invokes `ManualParser` on the manual entries file (default `config/soup-manual.json`) when it exists; parsed after auto-detected packages so a project can override an auto-detected entry by package name
- `enforce_vendored_coverage`: Fails the run (sets the error exit code) when a committed file matched by `--vendored_globs` has no SOUP entry, matched on the entry's `file` path or basename
- `read_cached_packages`: Loads previously entered user choices from cache
- `build_license_pattern`: Compiles `--licenses_file` into the allowlist matcher, anchoring every entry on word boundaries so a license that merely contains an allowlisted entry (e.g. npm's proprietary `UNLICENSED` containing `Unlicense`) no longer passes the compliance gate; an empty allowlist matches nothing rather than everything
- `apply_cached_metadata(name, package)`: Copies the four verification fields from the cache onto the package, and for a package whose registry lookup failed this run first calls `restore_unresolved_metadata`
- `restore_unresolved_metadata(package, cached)`: Restores `license`, `description`, and `website` from the cached entry when the package is marked `unresolved`, so a transient registry outage never downgrades an already-verified entry to `NOASSERTION`. Applied only when the cached entry records the *same* version, since licenses change between releases and carrying an older version's license onto a newly pinned one would assert something never verified
- `check_packages`: Validates licenses, then for each package applies cached metadata, applies the transitive-dependency defaults (`apply_dependency_defaults` writes the lowest risk level and `DEPENDENCY_TEXT`), prompts for anything still missing, stamps `last_verified_at`, and appends the markdown row
- `save_files`: The success path. Writes cache and markdown documentation files, replacing both wholesale — which is what lets a removed dependency drop out of the register. Only reached when every package completed `check_packages`
- `save_partial_state`: The failure path. Persists only the packages that finished the whole `check_packages` iteration (`Package#verified?`), merged over the cache read at startup, so an interrupted run keeps the verification work it did complete without blanking the metadata of packages it never reached. Deliberately does not write the markdown register, because `@markdown` holds only the rows appended before the failure and a stale-but-complete table beats a truncated one

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
- Configuration attributes: `cache_file`, `markdown_file`, `licenses_file`, `exceptions_file`, `manual_file`, `ignored_folders`, `vendored_globs`
- Skip flags: `skip_bundler`, `skip_composer`, `skip_gradle`, `skip_importmap`, `skip_npm`, `skip_pip`, `skip_spm`, `skip_yarn`
- Mode flags: `licenses_check`, `soup_check`, `no_prompt`, `auto_reply`

**External Dependencies:**

- `optparse`

### SOUP::Package

**Purpose:** Data model representing a third-party package with IEC 62304 required metadata.

**Location:** `lib/soup/package.rb`

**Key Components:**

- `self.sanitize_description(text, first_sentence:, strip_markdown:)`: Class method that sanitizes package descriptions by returning nil for nil/empty input, extracting the first sentence, wrapping URLs, and stripping markdown characters
- Parser-produced attributes, set once during `BaseParser#build_package` and treated as read-only afterwards: `file`, `language`, `package`, `version`, `license`, `description`, `website`, `dependency`
- Verification attributes, filled in by `Application#check_packages` from the cache, the dependency defaults, or the prompts: `last_verified_at`, `risk_level`, `requirements`, `verification_reasoning`
- `unresolved`: True when this run's registry lookup failed (network fault, 404 for a package absent from the registry, 403 for a private one) so license/description/website could not be fetched. Drives `Application#restore_unresolved_metadata`. Deliberately not serialized by `as_json` — it describes the run, not the package
- `verified?`: Returns true when all four verification fields (`last_verified_at`, `risk_level`, `requirements`, `verification_reasoning`) are non-empty
- `as_json`: Serializes the package to JSON format — the ten register columns only; `file`, `dependency`, and `unresolved` are run/parse state and are excluded
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
- `RegistryError`: Unrecoverable package metadata lookup failure. Never raised directly — it is the common parent that lets a caller rescue both registry-level aborts below at once
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
- `TRANSIENT_ERRORS`: Public constant listing every network fault treated as retryable — the timeouts (`Net::OpenTimeout`, `Net::ReadTimeout`, `Net::WriteTimeout`), dropped or refused connections (`Errno::ECONNRESET`, `Errno::EPIPE`, `Errno::ECONNREFUSED`, `Errno::EHOSTUNREACH`, `Errno::ENETUNREACH`), DNS failure (`SocketError`), TLS interruption (`OpenSSL::SSL::SSLError`), and truncated replies (`EOFError`, `Net::HTTPBadResponse`). It is the single source of truth: `self.get` retries this list and `BaseParser#registry_response` rescues this same constant, so the two can never drift apart. HTTP status codes are deliberately excluded — a 4xx/5xx is a response for the caller to inspect, not a transport failure
- `self.get(url, max_retries: nil, **options)`: Performs HTTP GET with automatic retry on every class in `TRANSIENT_ERRORS`, warning with the exception class and message on each attempt and re-raising once retries are exhausted

**External Dependencies:**

- `etc`
- `httparty`
- `net/http` (for the `Net::` timeout and bad-response classes in `TRANSIENT_ERRORS`)
- `openssl` (for `OpenSSL::SSL::SSLError` in `TRANSIENT_ERRORS`)

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
- `unresolved_package(name:, file:, language:, version:, dependency:)`: Records a package whose registry lookup failed, carrying everything the lock file already supplied (name, version, direct/transitive) with the license set to `NOASSERTION` and `Package#unresolved` set. A failed lookup is a metadata gap, not evidence the dependency is absent, so the entry stays in the register rather than being dropped (which would understate it) or aborting the run (which would discard every package resolved so far)
- `registry_response(url, label:, outcome:, **)`: The single GET entry point for every parser that talks to a registry. Absorbs the `HttpClient::TRANSIENT_ERRORS` fault `HttpClient.get` re-raises once its retries are exhausted, warning and returning nil — because `Parallel.map` propagates the first exception and aborts every other in-flight lookup, so one unreachable registry must not kill the whole scan. `label` names what is being skipped (the package for single-source parsers, the URL for Gradle's mirror loop) and `outcome` states what happens next, since most parsers record the package without registry metadata while Gradle only advances to the next repository
- `normalize_license(license)`: Maps URL-style license values (a link to a licence file names no licence) to `NOASSERTION`; every named identifier, `Unlicense` included, passes through so the `config/licenses.json` allowlist can match it
- `sibling_file(file, suffix)`: Resolves a sibling manifest path next to a lock file
- `manifest_mentions?(main_file, token)`: Token-boundary test for whether a dependency is declared directly in a source-code manifest; matches only when `token` is not flanked by identifier characters so a name that is a substring of another coordinate (e.g. `androidx.core:core` vs `androidx.core:core-ktx`) is not misclassified. Used by the Gradle and SPM parsers
- `lookup_npm_registry_version(payload, name:, version:)`: Extracts a specific version hash from an npm-style registry payload; shared by the NPM, Yarn, and Importmap parsers
- `npm_registry_url(name)` / `npm_registry_response(name:, label:)`: Build the packument URL for an npm package name and fetch it through `registry_response`; shared by the three npm consumers (NPM, Yarn, Importmap). NPM and Yarn know the version up front and pass a `name@version` label; Importmap resolves the version from that very response and so can only name the package
- `build_npm_registry_package(file:, name:, version:, package_details:, dependency:)`: Builds a `SOUP::Package` from an npm-registry per-version payload, sharing the `JS` language tag and the license/description/website extraction across the three npm consumers, which differ only in how the version became known and whether the package is direct
- `npm_registry_license(raw_license)`: Coerces the npm registry `license` field to a plain string, so the legacy object form (`{"type": "MIT", "url": ...}`) returned for older package versions does not reach `validate_license` as a Hash; shared by the NPM and Yarn parsers
- `empty_response?(response)`: The guard every parser applies to a `registry_response` result before parsing it — true when the lookup returned no response at all (a transient fault was swallowed) or returned an empty body, both of which are recorded via `unresolved_package`. It replaces the former `response.nil?` guard, which only covered the empty-body case because `HTTParty::Response` overrides `#nil?` to mean "body is nil or empty"; that override is deprecated, so the guard emitted a deprecation warning per lookup and would have silently narrowed to a plain object check on removal, letting empty bodies reach `JSON.parse`. It deliberately tests `unless response` rather than `response.nil?`, since calling `#nil?` on the response is itself the deprecated call
- `http_error_message(response, url:, package:)`: Builds an actionable error message (status code, URL, package, truncated body) for non-2xx responses
- `NOASSERTION_LICENSE`: Public constant for the `NOASSERTION` license value
- `NPM_REGISTRY_ROOT`: Private constant for the npm registry base URL consumed by `npm_registry_url`

**External Dependencies:**

- `parallel`

### SOUP::BundlerParser

**Purpose:** Parses Ruby Gemfile.lock files and fetches metadata from RubyGems API.

**Location:** `lib/soup/parsers/bundler.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file via `Bundler::LockfileParser` and fetches package details from RubyGems, fetching metadata for all specs in parallel via the inherited `parallel_each` helper (`BaseParser`). Direct dependencies are the lock file's `DEPENDENCIES` section, which lists exactly the gems declared in the `Gemfile`
- `fetch_package(...)`: Queries the versioned RubyGems endpoint first; when that version is not published (e.g. a platform-specific or yanked release) it resolves the gem's latest version and re-queries that version's endpoint. A swallowed network fault at any step short-circuits the chain — the registry is unreachable after every retry, so the remaining fallbacks would fail identically — and every dead end warns and records the gem via `unresolved_package` rather than aborting the scan

**External Dependencies:**

- `bundler`
- `json`

### SOUP::ComposerParser

**Purpose:** Parses PHP composer.lock files.

**Location:** `lib/soup/parsers/composer.rb`

**Key Components:**

- `parse(file, packages)`: Parses `packages` and `packages-dev` from the lock file and extracts metadata entirely from the lock file itself; one of the two parsers (with `ManualParser`) that makes no registry call, so it does not use `parallel_each`. Direct dependencies are the exact `require`/`require-dev` keys of the sibling `composer.json`
- `extract_composer_license(raw)`: Normalizes the Composer `license` field, which the schema permits as either a single string or an array of SPDX strings

**External Dependencies:**

- `json`

### SOUP::GradleParser

**Purpose:** Parses Kotlin/Gradle `buildscript-gradle.lockfile` (buildscript classpath) and `gradle.lockfile` (runtime classpath) files, and fetches metadata from Maven repositories.

**Location:** `lib/soup/parsers/gradle.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details, in parallel via the inherited `parallel_each` helper (`BaseParser`). Selects `classpath` entries for `buildscript-gradle.lockfile` and non-test, non-debug `RuntimeClasspath` entries for `gradle.lockfile`
- `fetch_package(...)`: Queries the `search.maven.org` solrsearch endpoint first; when it returns no single match, or times out (the endpoint is chronically flaky), the lookup degrades to the per-repository POM mirrors in `REPOSITORY_URLS` rather than aborting the run. A coordinate that no source resolves is warned and skipped
- Mirror failures are absorbed by the inherited `BaseParser#registry_response`, which swallows any `HttpClient::TRANSIENT_ERRORS` fault on one mirror (warned, returns nil) so the caller falls through to the next source, instead of `Parallel.map` propagating the exception and aborting every other in-flight lookup. It is passed an explicit `outcome` (`trying the per-repository POM fallbacks`, then `trying the next repository`) so the warning does not claim the package was recorded
- `read_main_gradle_file(file)`: Resolves the build script next to the lock file, trying the Groovy DSL `build.gradle` then the Kotlin DSL `build.gradle.kts` (the Gradle 8.x+ default for new Android/Kotlin projects); raises `InvalidLockfileError` when neither exists. The contents are passed to `manifest_mentions?` for direct/transitive classification
- `unresolved_message(response, url:, package:)`: Builds the skip warning, falling back to an "all Maven lookups timed out" message when every source timed out and there is no HTTP status to report
- `REPOSITORY_URLS`: Private constant listing the Maven POM mirror URLs (`maven.google.com`, `plugins.gradle.org/m2`, `jitpack.io`, the Sonatype snapshots repo) tried in order when the primary endpoint has no match
- `MAIN_FILE_NAMES`: Private constant listing the build script names tried by `read_main_gradle_file`

**External Dependencies:**

- `net/http`
- `nokogiri`

### SOUP::NPMParser

**Purpose:** Parses JavaScript package-lock.json files and fetches metadata from NPM registry.

**Location:** `lib/soup/parsers/npm.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from NPM registry in parallel via the inherited `parallel_each` helper (`BaseParser`). Requires `lockfileVersion` 2 or later (a lock file with no `packages` key raises `UnsupportedFormatError`); `dev` entries are excluded, and direct dependencies are the exact `dependencies`/`devDependencies` keys of the sibling `package.json`

**External Dependencies:**

- None; the registry fetching and parallelization are inherited from `SOUP::BaseParser`

### SOUP::PIPParser

**Purpose:** Parses Python requirements.txt files and fetches metadata from PyPI.

**Location:** `lib/soup/parsers/pip.rb`

**Key Components:**

- `parse(file, packages)`: Parses requirements file and fetches package details from PyPI in parallel via the inherited `parallel_each` helper (`BaseParser`). Only exact `==` pins are supported; comments and PEP 508 environment markers are stripped, and a line carrying a loose constraint (`>=`, `~=`, `!=`, `<`, `>`) is warned about and skipped
- `read_direct_dependencies(file)`: Reads the sibling `requirements.in` (the compiled-from source) for the direct dependency names; with no `.in` file every package stays transitive
- `normalize_pip_name(name)`: PEP 503 name normalization (lowercase, runs of `-`, `_`, `.` collapsed to `-`) so direct/transitive matching is case- and separator-insensitive
- `extract_pip_license(info)`: Prefers the PyPI trove `License ::` classifiers and falls back to the raw `license` field
- `LOOSE_CONSTRAINT_PATTERN`: Private constant matching the `<`, `>`, `!`, `~` characters that mark an unsupported non-exact pin
- `REQUIREMENT_NAME_PATTERN`: Private constant matching the leading PEP 508 distribution name of a `requirements.in` line, before any extras, constraint, or environment marker

**External Dependencies:**

- `json`

### SOUP::SPMParser

**Purpose:** Parses Swift Package Manager Package.resolved files and fetches metadata from GitHub API.

**Location:** `lib/soup/parsers/spm.rb`

**Key Components:**

- `parse(file, packages)`: Parses resolved file (both the v1 `object` wrapper and the flat v2+ shape) and fetches package details from GitHub API in parallel via the inherited `parallel_each` helper (`BaseParser`). A pin that resolves to a private repository is warned about but still recorded with the metadata GitHub returned — the lookup succeeded, and a private component belongs in the register like any other
- `pin_version(pin)`: Resolves the pinned identifier, taking the state's `version`, `branch`, or `revision` so branch- and revision-based pins are recorded rather than left empty
- `github_repo_path(location)`: Extracts `owner/repo` from the HTTPS, HTTPS-with-`.git`, or SSH form of a pin location
- `github_error_message(response)`: Reads GitHub's actionable error text from the JSON body's `message` field (where the rate-limit and bad-credentials strings live) rather than the HTTP reason phrase
- `read_main_swift_file(file)`: Resolves the direct-dependency manifest for `Package.resolved` files that are nested inside an Xcode project bundle by trying, in order, a sibling `Package.swift` (or matching `<Name>.swift`), an enclosing `Tuist/Dependencies.swift` when the resolved file lives under a Tuist directory, a sibling `<Name>.xcodeproj/project.pbxproj`, and finally the `project.pbxproj` of an enclosing `*.xcodeproj` higher up the tree (`enclosing_xcodeproj_pbxproj`, `tuist_dependencies_path`, `path_join` are its helpers). `parse` raises `InvalidLockfileError` when none of them resolves; otherwise the manifest is passed to `manifest_mentions?` to classify direct vs transitive dependencies
- `GITHUB_URL_NOISE`: Private constant stripping the GitHub host prefix and `.git` suffix consumed by `github_repo_path`
- Supports `GITHUB_TOKEN` environment variable for rate limit handling

**External Dependencies:**

- `json`

### SOUP::YarnParser

**Purpose:** Parses JavaScript yarn.lock files and fetches metadata from NPM registry.

**Location:** `lib/soup/parsers/yarn.rb`

**Key Components:**

- `parse(file, packages)`: Parses lock file and fetches package details from NPM registry in parallel via the inherited `parallel_each` helper (`BaseParser`). Only Yarn v1 lock files are supported — an unparseable file raises `UnsupportedFormatError`. Locally vendored packages whose `package.json` spec starts with `file:vendor` are excluded
- `manifest_dependency_specs(main_file_json)`: Merges the sibling `package.json` `dependencies`, `devDependencies`, `optionalDependencies`, and `peerDependencies` into a name-to-spec map that drives both the direct-dependency flag and the `file:vendor` exclusion
- `DEPENDENCY_SECTIONS`: Private constant listing the four `package.json` dependency sections read above

**External Dependencies:**

- `json`
- `yarn_lock_parser`

### SOUP::ImportmapParser

**Purpose:** Parses a Rails importmap pin file (`config/importmap.rb`) and treats CDN-pinned dependencies as third-party SOUP, fetching metadata from the NPM registry.

**Location:** `lib/soup/parsers/importmap.rb`

**Key Components:**

- `parse(file, packages)`: Reads `pin` directives, keeps only pins that resolve to an http(s) CDN URL (esm.sh, jspm.io, jsdelivr), derives the npm package name and version from the URL, and fetches metadata in parallel via the inherited `parallel_each` helper (`BaseParser`). Local/vendored pins (e.g. `application`, `@hotwired/*`, `*.js` under `vendor/`) are skipped. Unpinned "latest" pins resolve to the registry's latest dist-tag
- `name_and_version_from_url(url)`: Strips the protocol/host and CDN routing prefix, then reads the scoped or plain npm package name and the optional `@version` that follows it
- `PIN_REGEX`: Private constant matching `pin "name", to: "url"` directives
- Reuses the npm helpers in `BaseParser` — `npm_registry_response`, `lookup_npm_registry_version`, and `build_npm_registry_package` — rather than holding its own registry URL. Every importmap pin is recorded as a direct dependency (`dependency: false`)

### SOUP::ManualParser

**Purpose:** Reads manually-declared SOUP entries from a JSON file (default `config/soup-manual.json`) for vendored files and proprietary/commercial components that no package manager or registry can resolve.

**Location:** `lib/soup/parsers/manual.rb`

**Key Components:**

- `parse(file, packages)`: Parses a JSON array of entry objects, raising `InvalidLockfileError` if the file is not an array or an entry lacks a non-empty `package`; each entry becomes a `SOUP::Package`
- Each entry supports `package` (required), plus optional `language`, `version`, `license`, `description`, `website`, and `file`; the `file` path lets the vendored-file coverage check (`Application#enforce_vendored_coverage`) match a committed file to its entry
- Entries may pre-declare verification fields (`risk_level`, `requirements`, `verification_reasoning`); otherwise they fall back to the cache or prompt like any other package
- `REQUIRED_KEY`: Private constant for the required `package` field

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

1. Iterates through the `PARSER_REGISTRY` lock file names
2. Uses glob pattern to find matching files recursively
3. Excludes `node_modules/` and `vendor/` directories
4. Excludes user-specified ignored folders
5. Skips files whose package manager is disabled by a skip flag — the guard runs before the "Reading file" announcement so a dropped file is never announced
6. Delegates to the appropriate parser through `SOUP::GenericParser`, which type-checks the parser, file path, and packages hash
7. Runs `parse_manual_entries` and then `enforce_vendored_coverage` once every lock file has been parsed

**Complexity:** O(n) where n is the number of files in the project

### License Validation Algorithm

**Purpose:** Validates that all dependencies use approved open-source licenses.

**Location:** `lib/soup/application.rb` in `validate_license` and `build_license_pattern` methods (both invoked from `check_packages`)

**Implementation:**

1. `build_license_pattern` loads the authorized licenses and compiles them into a single matcher, anchoring each entry on word boundaries (`(?<!\w)entry(?!\w)`, with `Regexp.escape` applied so operator-supplied entries cannot inject regex metacharacters)
2. Loads package-specific exceptions from configuration file
3. For each detected package with a license:
   - Checks if the license matches any authorized entry on a word boundary (case-insensitive)
   - Checks if package is in exceptions list
   - Reports error if license is not approved and not `NOASSERTION`

**Why word boundaries rather than substring or exact match:** allowlist entries are license *families* as often as exact identifiers — `Apache` is meant to cover `Apache-2.0`, `BSD` to cover `BSD-3-Clause` — so an exact-match test would reject nearly every real-world SPDX identifier. A plain substring test (the BUG-004 defect) went too far the other way: any license string that merely *contained* an entry passed the compliance gate, so npm's `UNLICENSED` (proprietary, no rights granted) passed on the strength of containing `Unlicense`. Word boundaries keep `apache` matching `apache-2.0` while stopping `unlicense` from matching `unlicensed`, because `-` and `.` are boundaries but a trailing letter is not.

Word-boundary anchoring cannot rescue an entry that is genuinely a substring of a non-compliant license *name*, so two allowlist entries were removed in the same change: bare `BSL` is replaced by the precise `BSL-1.0` and `BSL 1.0` for Boost, and `Copyright` (which matched virtually any proprietary notice) is dropped entirely. `BSL` is an abbreviation collision rather than a version series: `BSL-1.0` is the Boost Software License, permissive and the only version Boost has ever published, whereas "BSL 1.1" is the **Business** Source License — a different, source-available licence whose real SPDX identifier is `BUSL-1.1`. Both Boost spellings are listed because the `Boost` entry only covers the prose form, and neither `BSL` entry can match a `1.1` string — a bare copyright notice names no license, and `config/exceptions.json` is the intended mechanism for a package whose registry metadata is odd.

**A family entry cannot reach across a leading word character, so a prefixed identifier needs its own entry.** Word boundaries make `BSD` cover `BSD-3-Clause` (the `-` is a boundary) but not `0BSD`, because the leading `0` is a `\w` and the lookbehind rejects it. `0BSD` — the BSD Zero Clause License, OSI-approved and strictly more permissive than `BSD-2-Clause`, being that license with the attribution requirement removed — is therefore listed explicitly, alongside the `BSD Zero Clause` prose spelling that some registries emit. It is the only SPDX identifier in common use where an allowlisted family name is prefixed by an alphanumeric, which is why the lookbehind stays `(?<!\w)` rather than relaxing to `(?<![a-z])`: a named entry documents exactly what was approved, whereas admitting any digit prefix would loosen every entry in the file at once. When a future licence turns out to be prefixed the same way, add the identifier here — do not reach for `config/exceptions.json`, which is scoped to one package and would suppress genuine licence changes for it later.

### Direct vs Transitive Dependency Classification Algorithm

**Purpose:** Classifies each detected package as a direct dependency (declared in the project's manifest) or a transitive dependency (pulled in only by other packages), recorded in `SOUP::Package#dependency`.

**Location:** Per-parser, using helpers in `lib/soup/parsers/base.rb` (`SOUP::BaseParser`)

**Implementation:**

1. For parsers whose manifest is structured data that can be parsed into an exact dependency set (Bundler, Composer, NPM, PIP, Yarn), the direct dependency names are read from that data (the lock file's `DEPENDENCIES` section for Bundler, the sibling `composer.json`/`package.json` dependency sections, the sibling `requirements.in` for PIP) and matched against package names with an exact-name comparison — PEP 503-normalized for PIP so case and `-`/`_`/`.` separators compare equal
2. For parsers whose manifest is source code that cannot be parsed into an exact set (Gradle build scripts, Swift `Package.swift`/`pbxproj`), `manifest_mentions?(main_file, token)` performs a token-boundary regex match so a name that is a substring of another coordinate is not misclassified
3. A package is marked transitive (`dependency: true`) when it is not found among the direct dependencies

### Vendored Coverage Enforcement Algorithm

**Purpose:** Ensures that committed vendored JS files cannot silently bypass the SOUP register by requiring each one to have a corresponding entry.

**Location:** `lib/soup/application.rb` in `enforce_vendored_coverage` method

**Implementation:**

1. Returns early when no `--vendored_globs` are configured
2. Collects the `file` paths (and their basenames) declared by detected/manual packages
3. For each glob, expands matching files under the project root
4. Reports an error and sets the error exit code for any matched file whose relative path or basename is not declared, instructing the user to add it to the manual entries file

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
2. On any class in `TRANSIENT_ERRORS` (timeouts, connection resets/refusals, DNS failures, TLS interruptions, truncated replies):
   - Increments retry counter
   - Logs the retry attempt with the exception class, message, and counter
   - Retries up to the configured maximum (`DEFAULT_MAX_RETRIES`, 3 by default; overridable via `SOUP_HTTP_MAX_RETRIES`)
   - Raises the exception after max retries are exhausted, for `BaseParser#registry_response` to convert into a per-package skip

   Restricting this list to the two timeout classes was the ERR-001 defect: every other transient fault bypassed the retry loop on its first attempt and escaped into `Parallel.map`, which propagates the first exception and drops every other in-flight result — so a single connection reset aborted an entire multi-hundred-package scan.

### Parallel Metadata Fetching Algorithm

**Purpose:** Speeds up registry lookups by fetching package metadata concurrently instead of serially.

**Location:** `parallel_each` in `lib/soup/parsers/base.rb` (`SOUP::BaseParser`), invoked from the `parse` method of the Bundler, Gradle, Importmap, NPM, PIP, SPM, and Yarn parsers. The Composer and Manual parsers resolve everything locally and so do not use it

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
| Missing or malformed config file | Raises `ConfigurationError` when a configuration file is absent or contains invalid JSON | `lib/soup/application.rb` in `validate_config!` / `validate_json!` methods |
| Malformed cache file | Raises `ConfigurationError` before any state exists, so the `ensure`-block save cannot rewrite `.soup.json` with metadata-less entries or blank `docs/soup.md` | `lib/soup/application.rb` in `validate_cache_file!` method |
| API rate limiting | Raises `RateLimitError` (and `AuthenticationError` for bad credentials), suggesting `GITHUB_TOKEN` | `lib/soup/parsers/spm.rb` in `fetch_package` / `github_error_message` methods |
| Network timeouts | Retry up to 3 times via `SOUP::HttpClient`, then re-raise | `lib/soup/http_client.rb` in `get` method |
| Transient network fault after retries | Any `HttpClient::TRANSIENT_ERRORS` fault (timeout, connection reset/refusal, DNS failure, TLS interruption, truncated reply) is retried, then the single package is warned about and recorded as unresolved rather than aborting the scan | `lib/soup/parsers/base.rb` in `registry_response`, used by every parser |
| Empty registry response body | A response carrying no body has nothing for `JSON.parse` to read, so it is treated exactly like a swallowed network fault and the package is recorded as unresolved | `lib/soup/parsers/base.rb` in `empty_response?`, used by the Bundler, Importmap, NPM, PIP, SPM, and Yarn parsers |
| Non-2xx registry response | Warns with the status, URL, package, and truncated body built by `http_error_message`, then records the single package via `unresolved_package` so the scan continues; the run is not aborted. The only exceptions are SPM's rate-limit and bad-credentials responses (see the API rate limiting row), which are global conditions that would fail every remaining lookup identically | `lib/soup/parsers/bundler.rb`, `importmap.rb`, `npm.rb`, `pip.rb`, `spm.rb`, `yarn.rb` in `fetch_package` methods |
| Unsupported lock file format | Raises `UnsupportedFormatError` for a `package-lock.json` below `lockfileVersion` 2 and for a `yarn.lock` that is not Yarn v1 | `lib/soup/parsers/npm.rb`, `yarn.rb` in `parse` methods |
| Malformed manual entries file | Raises `InvalidLockfileError` when the file is not a JSON array or an entry lacks a non-empty `package` | `lib/soup/parsers/manual.rb` in `parse` method |
| Missing Gradle build script | Raises `InvalidLockfileError` when neither `build.gradle` nor `build.gradle.kts` sits alongside the lock file | `lib/soup/parsers/gradle.rb` in `read_main_gradle_file` method |
| Missing Swift manifest | Raises `InvalidLockfileError` when no `Package.swift`, Tuist `Dependencies.swift`, or enclosing `project.pbxproj` can be resolved for a `Package.resolved` | `lib/soup/parsers/spm.rb` in `parse` / `read_main_swift_file` methods |
| Maven source unreachable | An unreachable `search.maven.org` query or POM mirror is skipped (warned) and the lookup falls through to the next source; the scan is not aborted | `lib/soup/parsers/gradle.rb` in `fetch_package`, via `BaseParser#registry_response` |
| Missing package metadata | Logs warning and continues processing other packages | NPM, Gradle, SPM, Importmap parsers; `lookup_npm_registry_version` in `lib/soup/parsers/base.rb` |
| Registry outage for an already-recorded package | The unresolved entry keeps the license, description, and website a previous run recorded, restored from `.soup.json` and only when the cached entry pins the same version, so an outage cannot silently downgrade a verified component to `NOASSERTION` | `lib/soup/application.rb` in `apply_cached_metadata` / `restore_unresolved_metadata` methods |
| Missing required IEC 62304 fields | Raises `MissingMetadataError` in `--no_prompt` mode, prompts user otherwise | `lib/soup/application.rb` in `prompt_missing_field` / `ensure_metadata_complete!` methods |
| Partial execution failure | Persists only fully verified packages via the `ensure` block, merged over the existing cache, so progress is not lost and previously recorded IEC 62304 evidence is never blanked; the published markdown register is left untouched rather than truncated | `lib/soup/application.rb` in `execute` / `save_partial_state` methods |
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
| Unattended defaults | `--auto_reply` fills missing metadata with the lowest risk level and `Dependency` instead of prompting |
| Debug diagnostics | `DEBUG` environment variable prints the full backtrace on an unhandled error |
| Selective parsing | Skip flags allow excluding specific package managers |
| Folder exclusion | `--ignored_folders` allows excluding directories from scanning |
| Vendored coverage gate | `--vendored_globs` fails the run when a committed vendored file has no SOUP entry |
| Manual SOUP entries | `--manual_file` declares vendored/proprietary components with no registry source |
