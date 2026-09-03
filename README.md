# <img src="assets/owlook-icon.png" width="44" height="44" align="top" alt=""> Owlook

[![Checks](https://img.shields.io/github/actions/workflow/status/rpaweb/owlook/ci.yml?label=checks&logo=github)](https://github.com/rpaweb/owlook/actions/workflows/ci.yml)
[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)](LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-CC342D)](collector/.ruby-version)

CI, deploy, and background-job status for your Rails projects, surfaced as a
bar widget in Omarchy (Quattro) — instead of alt-tabbing between GitHub, a
terminal, and a queue dashboard.

## Installation

```bash
omarchy plugin add https://github.com/rpaweb/owlook --enable
```

One command. No systemd unit, no gem to install separately — the widget
runs its own collector in the background (see [How it runs](#how-it-runs)
below), so `omarchy plugin add` is the whole install.

Installing/enabling a plugin runs arbitrary code inside your long-lived
shell process — read it first, same as Omarchy's own warning for
third-party plugins.

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
- Ruby, managed by [mise](https://mise.jdx.dev/) (pinned via
  `collector/.ruby-version`) — no gems to install; the collector only
  shells out to CLIs (see below), never a `bundle install` for end users.
- The [`gh`](https://cli.github.com/) CLI, authenticated (`gh auth login`).
  Falls back to `GITHUB_TOKEN` if `gh` isn't available.
- The [`kamal`](https://kamal-deploy.org/) CLI, since deploy/queue tracking
  runs it directly — already installed if you're deploying with Kamal.

## How it runs

`BarWidget.qml` schedules its own collector: a `Timer` runs
`collector/bin/owlook-collector` (a plain Ruby script, vendored in this
same repo) every 30 seconds via Quickshell's own `Process` type, writing
results to `$XDG_RUNTIME_DIR/owlook.json`. `Panel.qml` reads that file
through a `FileView` — no polling on the QML side, no process the widget
itself has to manage beyond starting the next cycle. A cycle that's
still running when the next one would start is skipped, not stacked, so
a slow cycle (cold SSH connections, a project with many branches) never
piles up overlapping runs.

This means polling only happens while the Omarchy shell itself is
running — restarting it (`omarchy restart shell`, a theme change, a
crash) pauses updates until it comes back, same as any other bar widget.
For most use this is unnoticeable; there's no separate systemd service
to keep it running independently of the shell.

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

`OWLOOK_CONFIG` overrides the config path via the environment if needed
(default `~/.config/owlook/config.yml`).

## Troubleshooting

A destination stuck on `unreachable` even though you can SSH to it
yourself almost always means that server's key isn't loaded into
gpg-agent's SSH support specifically — the only agent this collector can
reach (confirmed live: the shell process's own environment has no
`SSH_AUTH_SOCK` either, same as any background process), regardless of
what your terminal uses:

```bash
SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/gnupg/S.gpg-agent.ssh ssh-add ~/.ssh/that_key
```

No restart needed — the next cycle picks it up.

## Development

```bash
cd collector
bundle install
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
