# RuboCop::SortedMethodsByCall

![Repobeats](https://repobeats.axiom.co/api/embed/7926fec94bffd7fcaa69700fb9464ed96cf69083.svg "Repobeats analytics image")
[![CI](https://github.com/unurgunite/rubocop-sorted_methods_by_call/actions/workflows/ci.yml/badge.svg)](https://github.com/unurgunite/rubocop-sorted_methods_by_call/actions)
[![Gem Version](https://badge.fury.io/rb/rubocop-sorted_methods_by_call.svg)](https://rubygems.org/gems/rubocop-sorted_methods_by_call)

* [RuboCop::SortedMethodsByCall](#rubocopsortedmethodsbycall)
    * [Features](#features)
    * [Installation](#installation)
    * [Configuration](#configuration)
        * [Basic Setup](#basic-setup)
        * [Configuration Options](#configuration-options)
            * [Ordering Strategies](#ordering-strategies)
                * [`waterfall` (default)](#waterfall-default)
                * [execution_order](#execution_order)
            * [When to Use Each Strategy](#when-to-use-each-strategy)
    * [Practical Recommendation](#practical-recommendation)
    * [Usage Examples](#usage-examples)
        * [Good Code (waterfall order)](#good-code-waterfall-order)
        * [Bad Code (violates waterfall order)](#bad-code-violates-waterfall-order)
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

**Enforces "waterfall" method ordering**: define methods *after* any method that calls them within the same scope.

## Features

- **Waterfall ordering enforcement**: Caller methods must be defined before their callees
- **Smart visibility handling**: Respects `private`/`protected`/`public` sections
- **Safe mutual recursion**: Handles recursive method calls gracefully
- **Autocorrection support**: Automatically reorders methods (opt-in with `-A`)
- **Full RuboCop integration**: Works seamlessly with modern RuboCop plugin system
- **Comprehensive scope support**: Classes, modules, singleton classes, and top-level

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

#### Ordering Strategies

The cop supports two different method ordering strategies via the `OrderingStrategy` configuration:

##### `waterfall` (default)

Enforces **waterfall ordering** where callees are defined **after** their callers. This creates a top-down reading flow
where main logic appears before helper methods.

```ruby
# Good (waterfall order)
def main_logic
  helper_method
end

def helper_method
  # implementation
end
```

##### execution_order

Enforces execution ordering where methods are defined in the same order they are called within each method. This creates
a linear execution flow that matches runtime behavior.

```ruby
# Good (execution order)
def process_data
  validate_input # called first
  transform_data # called second
  save_results # called third
end

def validate_input # defined first (called first)  
  # implementation
end

def transform_data # defined second (called second)
  # implementation
end

def save_results # defined third (called third)
  # implementation
end
```

Complete Configuration Example

```yaml
SortedMethodsByCall/Waterfall:
  Enabled: true
  SafeAutoCorrect: false          # Autocorrection requires -A flag
  AllowedRecursion: true          # Allow mutual recursion (default: true)
  OrderingStrategy: "waterfall"   # or "execution_order"
```

#### When to Use Each Strategy

- Use waterfall (default) for:
    - Complex business logic with nested helper methods
    - Code where you want to understand the high-level flow first
    - Traditional object-oriented design
- Use execution_order for:
    - Service objects and command patterns
    - Sequential processing pipelines
    - Rails controllers and service classes
    - Code where execution order is important to understand

> Note: The execution_order strategy is particularly well-suited for Rails service objects where methods are typically
> called in a specific sequence.

## Practical Recommendation

For your specific use case with Rails service objects like this:

```ruby
class Service
  def call
    foo # called first
    bar # called second
  end

  private

  def foo
    123
  end

  def bar
    333
  end
end
```

You would want to use `execution_order` strategy, which would enforce:

```ruby

class Service
  def call
    foo # called first
    bar # called second
  end

  private

  def foo # defined first (called first)
    123
  end

  def bar # defined second (called second)
    333
  end
end
```

This makes the code much more readable because the method definitions follow the same order as the execution flow!

The default waterfall strategy would actually want the opposite order (`#bar` before `#foo`), which doesn't make sense
for sequential service objects.

So for Rails applications, you'll likely want to set OrderingStrategy: "execution_order" in your .rubocop.yml.

## Usage Examples

### Good Code (waterfall order)

```ruby
class Service
  def call
    bar
  end

  private

  def bar
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
    bar
  end

  private

  def foo # ❌ Offense: Define #foo after its caller #bar
    123
  end

  def bar
    foo
  end
end
```

### Autocorrection

Run with unsafe autocorrection to automatically fix violations:

```bash
bundle exec rubocop -A
```

This will reorder the methods while preserving comments and visibility modifiers:

```ruby
class Service
  def call
    bar
  end

  private

  def bar
    foo
  end

  def foo
    123
  end
end
```

## Testing

Run the test suite:

```bash
bundle exec rspec
```

Run RuboCop on the gem itself:

```bash
bundle exec rubocop
bundle exec rubocop --config .rubocop.test.yml lib/ -A
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

- **Ruby**: >= 2.7
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

The gem is available as open source under the terms of
the [BSD 3-Clause License](https://opensource.org/licenses/BSD-3-Clause).

## Code of Conduct

Everyone interacting with this project is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

---

> **Note**: This gem is now stable and ready for production use! The "waterfall" ordering pattern helps create more
> readable code by ensuring that methods are defined in the order they're conceptually needed.
