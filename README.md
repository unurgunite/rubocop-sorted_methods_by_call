# RuboCop::SortedMethodsByCall

![Alt](https://repobeats.axiom.co/api/embed/7926fec94bffd7fcaa69700fb9464ed96cf69083.svg "Repobeats analytics image")

# ! WARNING !

**This project is not updated yet and needs some improvements in code semantics. If you able to help this project, fork
it and make pull requests.**

Welcome to the rubocop-sorted_methods_by_call gem! This repo contains main sources of project.

## Documentation content

1. [Overview][1]
2. [Installation][2]
    1. [Build from source][2.1]
        1. [Manual installation][2.1.1]
        2. [Automatic installation][2.1.2]
    2. [Build via bundler][2.2]
3. [Usage][3]
    1. [Code examples][3.1]
4. [Todo][4]
5. [Development][5]
6. [Requirements][6]
    1. [Common usage][6.1]
    2. [Development purposes][6.2]
7. [Project style guide][7]
8. [Contributing][8]
9. [License][9]
10. [Code of Conduct][10]

## Overview

This gem analyze Ruby AST and check if code was written according to the "waterfall" feature which give flexibility to
sources by declaring methods after they are called.

## Installation

rubocop-sorted_methods_by_call gem is quite simple to use and install. There are two options to install it — for those
who is going to contribute into the project and for those who is going to embed gem to theirs project. See below for
each step.

### Build from source

#### Manual installation

The manual installation includes installation via command line interface. it is practically no different from what
happens during the automatic build of the project:

```shell
git clone https://github.com/unurgunite/rubocop-sorted_methods_by_call.git && \
cd rubocop-sorted_methods_by_call && \
bundle install && \
gem build rubocop-sorted_methods_by_call.gemspec && \
gem install rubocop-sorted_methods_by_call-0.1.0.gem
```

Now everything should work fine. Just type `irb`
and `require "rubocop-sorted_methods_by_call/rubocop-sorted_methods_by_call"` to start working with the library

#### Automatic installation

The automatic installation is simpler but it has at least same steps as manual installation:

```shell
git clone https://github.com/unurgunite/rubocop-sorted_methods_by_call.git && \
cd rubocop-sorted_methods_by_call && \
bin/setup
```

If you see `irb` interface, then everything works fine. The main goal of automatic installation is that you do not need
to create your own script to simplify project build and clean up the shell history. Note: you do not need to require
projects file after the automatic installation. See `bin/setup` file for clarity of the statement

### Build via bundler

This documentation point is close to those who need to embed the library in their project. Just place this gem to your
Gemfile or create it manually via `bundle init`:

```ruby
# Your Gemfile
gem 'rubocop-sorted_methods_by_call'
```

And then execute:

```shell
bundle install
```

Or install it yourself for non bundled projects as:

```shell
gem install rubocop-sorted_methods_by_call
```

## Usage

All docs are available at the separate page: https://unurgunite.github.io/rubocop-sorted_methods_by_call_docs/

### Code examples

Positive case:

```ruby
# file.rb
def foo
  bar
end

def bar
  123
end

# main.rb
require "parser/current"

code = Parser::CurrentRuby.parse(File.read("file.rb"))
ast = RuboCop::SortedMethodsByCall::Processor.new
ast.process(code)
ast.ordered? #=> true
```

Negative case:

```ruby
# file.rb
def bar
  123
end

def foo
  bar
end

# main.rb
require "parser/current"

code = Parser::CurrentRuby.parse(File.read("file.rb"))
ast = RuboCop::SortedMethodsByCall::Processor.new
ast.process(code)
ast.ordered? #=> false
```

## TODO

- [ ] Add recursion support
- [ ] Add classes support
- [ ] Add struct support
- [ ] Add modules support
- [ ] Add nested structures support
- [ ] Add standalone method support (without invoking another methods inside)
- [ ] Add detection for method overriding (namespace pollutions)
- [ ] Support for method calling inside of params
- [ ] Refactor code base
- [ ] Make more examples for specs

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can
also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the
version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version,
push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Requirements

This section will show dependencies which are used in the project. This section splits in two other sections —
requirements for common use and requirements for the development purposes.

### Common use

The `rubocop-sorted_methods_by_call` gem is built on top of another gem:

| Dependencies  | Description                                                   |
|---------------|---------------------------------------------------------------|
| [Parser][101] | Parser is used to build AST for future structure identifying. |

### Development purposes

For the development purposes `rubocop-sorted_methods_by_call` gem uses:

| Dependencies   | Description                                                                              |
|----------------|------------------------------------------------------------------------------------------|
| [RSpec][201]   | The RSpec gem is used for test which are located in a separate folder under `spec` name. |
| [RuboCop][202] | The RuboCop gem is used for code formatting.                                             |
| [Rake][203]    | The Rake gem is used for building tasks as generating documentation.                     |                                                                                             |
| [YARD][204]    | The YARD gem is used for the documentation.                                              |
| [Parser][205]  | The Parser gem is used for building AST.                                                 |

## Project style guide

To make the code base much cleaner gem has its own style guides. They are defined in a root folder of the gem in
a [CONTRIBUTING.md](https://github.com/unurgunite/rubocop-sorted_methods_by_call/blob/master/CONTRIBUTING.md) file.
Check it for more details.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/unurgunite/rubocop-sorted_methods_by_call.
This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to
the [code of conduct](https://github.com/unurgunite/rubocop-sorted_methods_by_call/blob/master/CODE_OF_CONDUCT.md). To
contribute you should fork this project and create there new branch:

```shell
git clone https://github.com/your-beautiful-username/rubocop-sorted_methods_by_call.git && \
git checkout -b refactor && \
git commit -m "Affected new changes" && \
git push origin refactor
```

And then make new pull request with additional notes of what you have done. The better the changes are scheduled, the
faster the PR will be checked.

## Code of Conduct

Everyone interacting in the `RuboCop::SortedMethodsByCall` project's codebases, issue trackers, chat rooms and mailing
lists is expected
to follow
the [code of conduct](https://github.com/unurgunite/rubocop-sorted_methods_by_call/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of
the [New BSD License](https://opensource.org/licenses/BSD-3-Clause). The
copy of the license is stored in project under the `LICENSE.txt` file
name: [copy of the License](https://github.com/unurgunite/rubocop-sorted_methods_by_call/blob/master/LICENSE.txt)

The documentation is available as open source under the terms of
the [CC BY-SA 4.0 License](https://creativecommons.org/licenses/by-sa/4.0/)

The other libs are available as open source under the terms of
the [New BSD License](https://opensource.org/licenses/BSD-3-Clause)

![CC BY-SA 4.0](https://mirrors.creativecommons.org/presskit/buttons/88x31/svg/by-nc.svg)
![BSD license logo](https://upload.wikimedia.org/wikipedia/commons/4/42/License_icon-bsd-88x31.png)

[1]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#overview

[2]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#installation

[2.1]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#build-from-source

[2.1.1]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#manual-installation

[2.1.2]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#automatic-installation

[2.2]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#build-via-bundler

[3]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#usage

[3.1]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#code-examples

[4]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#todo

[5]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#development

[6]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#requirements

[6.1]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#common-usage

[6.2]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#development-purposes

[7]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#project-style-guide

[8]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#contributing

[9]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#license

[10]:https://github.com/unurgunite/rubocop-sorted_methods_by_call#code-of-conduct

[101]:https://rubygems.org/gems/parser

[201]:https://rubygems.org/gems/rspec

[202]:https://rubygems.org/gems/rubocop

[203]:https://rubygems.org/gems/rake

[204]:https://rubygems.org/gems/yard

[205]:https://rubygems.org/gems/parser
