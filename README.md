# Software of Unknown Provenance (SOUP)

The IEC 62304 requires you to document your SOUP, which is short for Software of Unknown Provenance. In human language,
those are the third-party libraries you’re using in your code. This tool helps produce that list and also check for any
software licenses that may be dangerous in commercial products. It is intended to be used in interactive mode and in
continuous integration (CI) pipelines.

The following package managers are supported:

- Composer (composer.lock)
- Bundler (Gemfile.lock)
- SPM (Package.resolved)
- CocoaPods (Podfile.lock)
- PIP (requirements.txt)

The soup file is generated in `./docs/soup.md` and a cache file `.soup.json` is used to preserved previously entered
choices.

## Installation

You can run `bundle install` and then run the command `soup` or you can install the latest via homebrew
with `brew install cloud-officer/brew/soup`.

## Usage

Run `soup.rb` in the root of the project.

```bash
options
        --licenses         Check for licenses
        --no_prompt        Fail immediately without prompting for the missing information (useful for CI)
        --skip_bundler     Skip Bundler files even if detected
        --skip_cocoapods   Skip CocoaPods files even if detected
        --skip_composer    Skip Composer files even if detected
        --skip_pip         Skip PIP files even if detected
        --skip_spm         Skip SPM files even if detected
        --soup             Generate soup file with list of SOUP detected
    -h, --help             Show this help
```

## Examples

Only check for licenses.

```bash
soup.rb --licenses
```

Generate soup and check for licenses but with Bundler.

```bash
soup.rb --skip_bundler
```

Only check if list of soup is completed without prompting.

```bash
soup.rb --soup --no_prompt
```
