# Changelog

## [1.2.3] - 2026-06-12

### Added
- RBS type signatures for all source files (`sig/`)
- Steep type checker integration (`Steepfile`, `steep check` in CI)
- RBS collection via `rbs collection install`
- Patch stub for `RuboCop::Cop::AutoCorrector` (RBS collection places it in wrong namespace)
- Docscribe documentation for all ~50 methods with meaningful descriptions
- `docscribe.yml` configuration
- `docscribe lib` step in CI
- RBS validation + Steep check in CI (Ruby >= 3.2)
- CONTRIBUTING.md, SECURITY.md, issue/PR templates
- CHANGELOG.md

### Changed
- Gemfile: `rbs` and `steep` in `:rbs` group, conditional on Ruby >= 3.2
- CI: manual `bundle install` (no `bundler-cache`) for cross-Ruby compatibility
- CI: split RBS/steep checks into conditional steps

### Fixed
- `CODE_OF_CONDUCT.md`: replaced placeholder email with link to GitHub Issues

## [1.2.2] - 2026-06-11

### Changed
- Updated version to 1.2.2

## [1.2.1] - 2026-06-11

### Changed
- Updated version to 1.2.1

## [1.2.0] - 2026-06-11

### Added
- Initial release of RuboCop::SortedMethodsByCall
- Waterfall ordering enforcement cop
- Autocorrect support
- Sibling ordering with cycle detection
- `SkipCyclicSiblingEdges` configuration option
