# RuboCop::SortedMethodsByCall

![Repobeats](https://repobeats.axiom.co/api/embed/7926fec94bffd7fcaa69700fb9464ed96cf69083.svg "Repobeats analytics image")
[![CI](https://github.com/unurgunite/rubocop-sorted_methods_by_call/actions/workflows/ci.yml/badge.svg)](https://github.com/unurgunite/rubocop-sorted_methods_by_call/actions)
[![Gem Version](https://badge.fury.io/rb/rubocop-sorted_methods_by_call.svg)](https://rubygems.org/gems/rubocop-sorted_methods_by_call)

**Enforces "waterfall" method ordering**: define methods *after* any method that calls them within the same scope.

* [RuboCop::SortedMethodsByCall](#rubocopsortedmethodsbycall)
    * [Features](#features)
    * [Installation](#installation)
    * [Configuration](#configuration)
        * [Basic Setup](#basic-setup)
        * [Configuration Options](#configuration-options)
    * [Usage Examples](#usage-examples)
        * [Good Code (waterfall order)](#good-code-waterfall-order)
        * [Bad Code (violates waterfall order)](#bad-code-violates-waterfall-order)
        * [Sibling ordering and cycles (why autocorrect can be skipped)](#sibling-ordering-and-cycles-why-autocorrect-can-be-skipped)
        * [Autocorrection](#autocorrection)
    * [Testing](#testing)
    * [Development](#development)
        * [Available Commands](#available-commands)
        * [Release Process](#release-process)
    * [Requirements](#requirements)
    * [Contributing](#contributing)
    * [Documentation](#documentation)
    * [License](#license)
    * [Code of Conduct](#code-of-conduct)

## Features

- **Waterfall ordering enforcement**: Caller methods must be defined before their callees;
- **Smart visibility handling**: Respects `private`/`protected`/`public` sections;
- **Safe mutual recursion**: Handles recursive method calls gracefully;
- **Autocorrection support**: Automatically reorders methods (opt-in with `-A`);
- **Full RuboCop integration**: Works seamlessly with modern RuboCop plugin system;
- **Comprehensive scope support**: Classes, modules, singleton classes, and top-level;

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'rubocop-sorted_methods_by_call'
```

And then execute:

```bash
bundle install
```

Or install it yourself:

```bash
gem install rubocop-sorted_methods_by_call
```

## Configuration

### Basic Setup

Add to your `.rubocop.yml`:

```yaml
plugins:
  - rubocop-sorted_methods_by_call

SortedMethodsByCall/Waterfall:
  Enabled: true
```

### Configuration Options

```yaml
SortedMethodsByCall/Waterfall:
  Enabled: true
  SafeAutoCorrect: false          # Autocorrection requires -A flag
  AllowedRecursion: true          # Allow mutual recursion (default: true)
  # If true, the cop will NOT add "called together" sibling-order edges
  # that would introduce a cycle with existing constraints. This reduces
  # impossible-to-fix sibling offenses and makes autocorrect more reliable.
  #
  # Default: false
  SkipCyclicSiblingEdges: false
```

## Usage Examples

### Good Code (waterfall order)

In waterfall ordering, **callers come before callees**. This creates a top-down reading flow where main logic appears
before implementation details.

```ruby

class Service
  def call
    foo
    bar
  end

  private

  def bar
    method123
  end

  def method123
    foo
  end

  def foo
    123
  end
end
```

### Bad Code (violates waterfall order)

```ruby

class Service
  def call
    foo
    bar
  end

  private

  def foo # ❌ Offense: Define #foo after its caller #method123
    123
  end

  def bar
    method123
  end

  def method123
    foo
  end
end
```

### Sibling ordering and cycles (why autocorrect can be skipped)

`SortedMethodsByCall/Waterfall` enforces two kinds of ordering constraints:

1. **Direct call edges**: if `caller` calls `callee`, then `caller` must be defined **before** `callee`.
2. **Sibling ("called together") edges**: in orchestration methods (methods not called by others in the same scope),
   consecutive calls imply an intended order (e.g., `a` then `b`), so `a` should be defined before `b`.

Sometimes these constraints can conflict and create a **cycle**, which means there is no valid ordering that satisfies
all constraints. In this situation, autocorrect may be skipped.

Example:

```ruby
class SiblingCycleExample
  def call
    a
    b
  end

  private

  def b
    c
  end

  def c
    a
  end

  def a; end
end
```

Here, the direct dependencies imply `b -> c -> a`, but the orchestration method implies `a -> b`,
which forms the cycle `a -> b -> c -> a`.

If you prefer to keep the warning (to encourage refactoring), leave `SkipCyclicSiblingEdges: false`.
If you prefer the cop to avoid enforcing sibling edges that create cycles, set `SkipCyclicSiblingEdges: true`.

### Autocorrection

Run with unsafe autocorrection to automatically fix violations:

```bash
bundle exec rubocop -A
```

This will reorder the methods while preserving comments and visibility modifiers.

## Testing

Run the test suite:

```bash
bundle exec rspec
```

Run RuboCop on the gem itself:

```bash
bundle exec rubocop
bundle exec rubocop --config test_project/.rubocop.test.yml lib/ -A
```

## Development

After checking out the repo, run:

```bash
bin/setup
```

This will install dependencies and start an interactive console.

### Available Commands

- `bin/console` - Interactive development console
- `bin/setup` - Install dependencies and build gem
- `bundle exec rake` - Run tests and linting

### Release Process

1. Update version in `lib/rubocop/sorted_methods_by_call/version.rb`
2. Create and push a git tag: `git tag v0.1.0 && git push origin v0.1.0`
3. GitHub Actions will automatically:
    - Build the gem
    - Publish to RubyGems.org
    - Create a GitHub release

## Requirements

- **Ruby**: >= 2.6
- **RuboCop**: >= 1.72.0 (required for plugin system)

## Contributing

Bug reports and pull requests are welcome! Please follow these guidelines:

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a pull request

Please ensure your code passes all tests and follows the existing style.

## Documentation

Code is covered with YARD docs, you can access online docs
at https://unurgunite.github.io/rubocop-sorted_methods_by_call_docs/

## License

The gem is available as open source under the terms of MIT License.

## Code of Conduct

Everyone interacting with this project is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

---

> **Note**: This gem implements **true waterfall ordering** that considers the complete call graph across all methods in
> a scope. Methods are ordered so that every callee appears after all of its callers, creating a natural top-down
> reading flow.
