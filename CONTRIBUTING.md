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
reproduce it — for anything CI/queue-status related, the collector logs
to the shell's own output (`console.log`, visible via `journalctl --user`,
grep for `[owlook]`); there's no separate service/unit to check.

## Pull Requests

- Ensure the test suite passes: `cd collector && bundle exec rake test`.
- Run the linter and fix any offenses: `bundle exec rubocop` (from `collector/`).
- Run the security scanners: `bundle exec bundler-audit check` (from
  `collector/`) and
  `semgrep scan --config p/ruby --config p/javascript --config p/security-audit collector/lib/ Model.js`
  (from the repo root).
- **Changed a `.qml`/`.js` file at the repo root?** CI can't validate QML
  for this project — `qs.Commons`/`qs.Ui` (Quickshell's own module
  system) only resolve inside a real, running Quickshell install, and
  there's no headless way around that (see the README's CI section for
  the full reasoning). Run `qmllint` on the changed files by hand, and —
  for anything beyond a trivial change — actually install the plugin
  locally (`rsync` this repo, minus `.git`, into
  `~/.config/omarchy/plugins/owlook.status/`, or symlink it) and confirm
  it renders correctly in a live Quattro shell before opening the PR.
- Keep changes focused on a single concern — a PR mixing an unrelated
  refactor with a bug fix is harder to review and harder to revert if
  something's wrong.
- Follow [Conventional Commits](https://www.conventionalcommits.org/)
  for commit messages (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`,
  `test:`, `perf:`, `style:`), imperative mood, in English.
- Add tests for new behavior — every `collector/lib/owlook/*` class has a
  corresponding `collector/test/owlook/*_test.rb`; new code should follow
  the same pattern.

## Development

Ruby >= 3.2 (`collector/.ruby-version` pins the specific version this
repo is developed on, managed with [mise](https://mise.jdx.dev/)).
Omarchy 4.x (Quattro) is needed to actually run the bar widget — see the
README's Requirements section for the full list (the `gh` and `kamal`
CLIs). No systemd unit to set up — see README's "How it runs".

```bash
cd collector
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

Owlook is released under [PolyForm Noncommercial 1.0.0](LICENSE). By
contributing, you agree to license your contributions under the same
terms.
