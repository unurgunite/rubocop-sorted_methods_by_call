# Contributing

Bug reports and pull requests are welcome!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone git@github.com:YOUR_USERNAME/rubocop-sorted_methods_by_call.git`
3. Install dependencies: `bin/setup`

## Making Changes

1. Create a feature branch: `git checkout -b feature/amazing-feature`
2. Make your changes
3. Run the test suite: `bundle exec rspec`
4. Run the linter: `bundle exec rubocop`
5. If you changed RBS signatures, run: `bundle exec rbs validate && bundle exec steep check`
6. Commit your changes: `git commit -am 'Add amazing feature'`
7. Push: `git push origin feature/amazing-feature`
8. Open a pull request

## Code Style

- Follow the existing code style
- All code must pass RuboCop (no offenses)
- Methods should be documented with YARD comments
- If adding or changing types, update the corresponding RBS signatures in `sig/`

## Testing

- All pull requests must maintain or improve test coverage
- Run `bundle exec rspec` to run the test suite
- Run `bundle exec rubocop` to check code style
- On Ruby >= 3.2, also run `bundle exec rbs validate && bundle exec steep check`

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
