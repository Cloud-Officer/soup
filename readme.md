# Software of Unknown Provenance (SOUP)

The IEC 62304 standard requires you to document your SOUP, which is short for Software of Unknown Provenance. In human language,
those are the third-party libraries you’re using in your code. This tool helps produce that list and also check for any
software licenses that may be dangerous in commercial products. It is intended to be used in interactive mode and in
continuous integration (CI) pipelines.

The `risk` is shall be interpreted like that:

* Low (can’t lead to harm)
* Medium (can lead to reversible harm)
* High (can lead to irreversible harm)

The `requirement` question/column is why you need this library in your project. Something like to handle request and
communication with the backend.

The `verification reasoning` question/column is why you selected this among all other choices. Something like most
popular and highest rated GitHub library for networking written in Swift.

The following package managers are supported:

* Composer (composer.lock)
* Bundler (Gemfile.lock)
* SPM (Package.resolved)
* CocoaPods (Podfile.lock)
* PIP (requirements.txt)
* Yarn (yarn.lock)

The soup file is generated in `./docs/soup.md` and a cache file `.soup.json` is used to preserved previously entered
choices.

## Installation

You can run `bundle install` and then run the command `soup` or you can install the latest via homebrew
with `brew install cloud-officer/ci/soup`.

## Usage

Run `soup` in the root of the project.

```bash
Usage: soup options

options
        --cache_file file            Path to cached file
        --exceptions_file file       Path to exception file
        --ignored_folders ignored_folders
                                     Comma separated list of folders to ignore
        --licenses                   Check for open source licenses compliance
        --licenses_file file         Path to authorized licenses file
        --markdown_file file         Path to generated markdown file
        --no_prompt                  Do not prompt for missing information and fail immediately
        --skip_bundler               Ignore Ruby/Bundler/Gemfile/Gemfile.lock even if detected
        --skip_cocoapods             Ignore Swift/CocoaPods/Podfile/Podfile.lock even if detected
        --skip_composer              Ignore PHP/Composer/composer.json/composer.lock even if detected
        --skip_pip                   Ignore Python/PIP/requirements.txt even if detected
        --skip_spm                   Ignore Swift/SPM/Package.swift/Package.resolved even if detected
        --skip_yarn                  Ignore JS/Yarn/package.json/yarn.lock even if detected
        --soup                       Check for missing information and generate the soup.md file
        --auto_reply                 Auto reply to questions prompt
    -h, --help                       Show this message

```

Depending on the package manager files detected, you may see an error `rate limit exceeded` if you have a lot of
packages and you run this tool many times. In this case
simply create a [Github personal access token](https://github.com/settings/tokens) and set it in the `GITHUB_TOKEN`
environment variable.

## Examples

Only check for licenses.

```bash
soup --licenses
```

Generate soup and check for licenses but with Bundler.

```bash
soup --skip_bundler
```

Only check if list of soup is completed without prompting.

```bash
soup --soup --no_prompt
```
