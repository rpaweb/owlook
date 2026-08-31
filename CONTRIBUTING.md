# Contributing to Owlook

Thank you for considering contributing to Owlook! This document outlines
some guidelines for contributing to this project.

There are several ways you can contribute:

- **Report an issue** — bugs, feature requests, or improvements, on the
  [Owlook GitHub Issues tracker](https://github.com/rpaweb/owlook/issues).
- **Submit patches** — [open a pull request](https://github.com/rpaweb/owlook/pulls)
  with a new feature or a fix.
- **Improve documentation** — the README is meant to explain not just what
  the project does but why it's built the way it is; corrections and
  clarifications are welcome.

## Issues

Check the [existing issues](https://github.com/rpaweb/owlook/issues) before
opening a new one. Include a clear description of the problem and steps to
reproduce it — for anything CI/queue-status related, the relevant
`journalctl --user -u owlook` output helps a lot.

## Pull Requests

- Ensure the test suite passes: `bundle exec rake test`.
- Run the linter and fix any offenses: `bundle exec rubocop`.
- Run the security scanners: `bundle exec bundler-audit check` and
  `semgrep scan --config p/ruby --config p/javascript --config p/security-audit lib/ shell/plugins/status/Model.js`.
- **Changed anything under `shell/`?** CI can't validate QML for this
  project — `qs.Commons`/`qs.Ui` (Quickshell's own module system) only
  resolve inside a real, running Quickshell install, and there's no
  headless way around that (see the README's CI section for the full
  reasoning). Run `qmllint` on the changed files by hand, and — for
  anything beyond a trivial change — actually install the plugin
  (`shell/plugins/status/` → `~/.config/omarchy/plugins/owlook.status`,
  see the README) and confirm it renders correctly in a live Quattro
  shell before opening the PR.
- Keep changes focused on a single concern — a PR mixing an unrelated
  refactor with a bug fix is harder to review and harder to revert if
  something's wrong.
- Follow [Conventional Commits](https://www.conventionalcommits.org/)
  for commit messages (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`,
  `test:`, `perf:`, `style:`), imperative mood, in English.
- Add tests for new behavior — every `lib/owlook/*` class has a
  corresponding `test/owlook/*_test.rb`; new code should follow the same
  pattern.

## Development

Ruby >= 3.2 (this repo pins a specific version via `.ruby-version`,
managed with [mise](https://mise.jdx.dev/)). Omarchy 4.x (Quattro) is
needed to actually run the bar widget — see the README's Requirements
section for the full list (the `gh` CLI, systemd running as your user).

```bash
bundle install
bundle exec rake test              # full suite, no network access needed
bundle exec rubocop                # style
bundle exec bundler-audit check    # dependency vulnerabilities
```

1. Fork the repository.
2. Create a branch for your change.
3. Make it, following the guidelines above.
4. Confirm the test suite and linters pass locally — CI runs the same
   checks, but catching it before pushing saves a round trip.
5. Open a pull request with a clear description of what changed and why.

## License

Owlook's license hasn't been decided yet — see [LICENSE](LICENSE).
