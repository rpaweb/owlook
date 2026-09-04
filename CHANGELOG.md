# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [SemVer](https://semver.org/) — under `0.x`, a MINOR bump signals
"expect breaking changes," a PATCH bump is a fix to what's already released.

## [Unreleased]

## [0.1.0] - 2026-09-04

One `omarchy plugin add` install, no systemd unit, no extra service to
install separately: the widget schedules its own vendored collector
(see README's "How it runs"), watching GitHub Actions, Kamal deploy
destinations, and Solid Queue background-job health across multiple
projects, surfaced as a bar widget in Omarchy (Quattro).

### Added

- GitHub Actions status per project, branches auto-detected from local
  `.github/workflows/*.yml` (an "all branches" broad mode is available as
  a setting), including which workflow produced the run.
- Deploy freshness per Kamal destination — how far the running SHA is
  behind the branch or git tag it was built from, whichever's the
  nearest match.
- Solid Queue health (backlog, dead jobs, active workers, oldest-waiting
  age) per Kamal destination, over the same SSH access `kamal deploy`
  already uses.
- A "stalled" state (distinct from ok/failing) for a destination with a
  real backlog but zero live workers — colored using the user's actual
  Omarchy theme (`colors.toml`'s `green`/`yellow`), not a hardcoded value.
- Desktop notifications on real state transitions only, never a repeat
  poll, using owlook's own icon rather than a generic glyph.
- A settings shortcut ("Edit tracked projects") that opens
  `~/.config/owlook/config.yml` in your configured editor.
- A real empty state when `config.yml` has zero projects configured —
  no tabs, a centered prompt to add one, Settings' gear icon hidden
  (nothing to configure until there's a project).
- Toggling "All branches" or editing `config.yml` takes effect
  immediately — the in-flight cycle is interrupted and restarted right
  away, instead of waiting up to 30s for the next scheduled poll.
- A 340×456 bar panel, one tab per project, with its own logo mark,
  including the bar-icon underline other Omarchy plugins show while
  their panel is open.

### Fixed

- One project's own poll failure (a transient GitHub API error, an
  unreachable destination) no longer kills the whole cycle — every
  other project still polls that cycle, and the failure is retried
  next time instead of silently freezing all state until the next
  successful run.
- CI/deploy polling across many branches or destinations is capped at
  20 concurrent requests, so a project with a lot of branches can't
  exhaust GitHub's rate limit or open unbounded SSH connections.
