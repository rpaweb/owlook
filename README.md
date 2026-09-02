# <img src="assets/owlook-icon.png" width="44" height="44" align="top" alt=""> Owlook

[![Gem Version](https://img.shields.io/gem/v/owlook)](https://rubygems.org/gems/owlook)
[![Checks](https://img.shields.io/github/actions/workflow/status/rpaweb/owlook/ci.yml?label=checks&logo=github)](https://github.com/rpaweb/owlook/actions/workflows/ci.yml)
[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)](LICENSE)
[![Downloads](https://img.shields.io/gem/dt/owlook)](https://rubygems.org/gems/owlook)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-CC342D)](owlook.gemspec)

CI, deploy, and background-job status for your Rails projects, surfaced as a
bar widget in Omarchy (Quattro) — one long-lived collector process instead
of alt-tabbing between GitHub, a terminal, and a queue dashboard.

## What it tracks

- **CI** — GitHub Actions status per branch, auto-detected from
  `.github/workflows/*.yml`. An **All branches** setting opts into every
  branch with a run instead (dependabot/renovate included).
- **Deploy** — what's actually running on each Kamal destination
  (`kamal app version`), and how fresh it is against CI or the repo's
  latest git tag — works whether a destination deploys from a branch or
  a release tag.
- **Queues** — Solid Queue backlog, dead jobs, and active workers, over
  the same SSH access `kamal deploy` already uses. No code added to the
  target app, no new credentials.
- **Notifications** — desktop alerts on real state transitions only,
  never a repeat poll.

See [CHANGELOG.md](CHANGELOG.md) for release history. Not built yet:
Sidekiq (behind the same source interface as Solid Queue), and any Git
host besides GitHub.

## Requirements

- Omarchy 4.x (Quattro) — targets the Quickshell-based shell.
- Ruby, managed by [mise](https://mise.jdx.dev/) (pinned via `.ruby-version`).
- The [`gh`](https://cli.github.com/) CLI, authenticated (`gh auth login`).
  Falls back to `GITHUB_TOKEN` if `gh` isn't available.
- systemd running as your user (`systemctl --user`).

## Installation

```bash
bundle install
bin/owlook-install-service        # renders + installs the systemd unit, does NOT enable it
systemctl --user daemon-reload
systemctl --user enable --now owlook
systemctl --user status owlook    # confirm it's active
```

Then the bar widget — not published anywhere yet, so install by hand:

```bash
cp -r shell/plugins/status ~/.config/omarchy/plugins/owlook.status
omarchy plugin validate ~/.config/omarchy/plugins/owlook.status
omarchy plugin enable owlook.status
```

Installing/enabling a plugin runs arbitrary code inside your long-lived
shell process — read it first, same as Omarchy's own warning for
third-party plugins.

## Configuration

`~/.config/owlook/config.yml`:

```yaml
projects:
  - ~/Work/oss/exampleapp
  - ~/Work/oss/another-project
```

That's the whole file — owner/repo, branches, and Kamal destinations are
all derived from each project's local checkout. Add or remove projects
freely; picked up on the next poll, no restart needed. The panel's
Settings view (gear icon) has a shortcut to open this file in your editor.

`OWLOOK_POLL_INTERVAL` (default `30`s, CI), `OWLOOK_QUEUE_POLL_INTERVAL`
(default `60`s, deploy + queue checks), and `OWLOOK_CONFIG` override the
defaults via the environment if needed.

## Troubleshooting

A destination stuck on `unreachable` even though you can SSH to it
yourself almost always means that server's key isn't loaded into
gpg-agent's SSH support specifically — the only agent a systemd `--user`
service can reach, regardless of what your terminal uses:

```bash
SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/gnupg/S.gpg-agent.ssh ssh-add ~/.ssh/that_key
```

No restart needed — the next poll picks it up.

## Development

```bash
bundle exec rake test              # full suite, no network access needed
bundle exec rubocop
```

Every `lib/owlook/*` class has a matching `test/owlook/*_test.rb`;
git-touching tests use real temporary repos, never a mocked git. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full PR checklist (Semgrep,
`bundler-audit`, and why `qmllint` stays a manual step instead of living
in CI).

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free for noncommercial use;
selling a derivative needs the licensor's permission.
