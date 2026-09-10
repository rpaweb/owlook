# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [SemVer](https://semver.org/) — under `0.x`, a MINOR bump signals
"expect breaking changes," a PATCH bump is a fix to what's already released.

## [Unreleased]

### Fixed

- "All branches" mode with no caching could burn through a large share
  of GitHub's hourly API rate limit on its own — a real user's `gh` CLI
  got locked out after leaving it on. GitHub responses are now cached
  and revalidated with conditional requests; a `304 Not Modified`
  response (the common case — nothing changed since the last poll)
  costs no quota at all, confirmed live against the real API.

## [0.1.3] - 2026-09-07

### Fixed

- A workflow run with no explicit `run-name:` set could show its CI row
  as several lines of raw commit text instead of a short label — GitHub
  defaults an unnamed run's name to the triggering commit message,
  which can span multiple lines. Only the first line is used now, and
  it renders as plain text rather than the implicit rich-text default.
- Installing the plugin with no `config.yml` yet crashed the collector
  outright, unguarded, with no indication of what to create. It now
  writes one for you on first run, with the expected format commented
  inline, and starts from zero tracked projects.

## [0.1.2] - 2026-09-07

### Security

- The bar panel rendered a GitHub branch name as rich text instead of
  plain text — a branch named to include markup could spoof the
  CI/deploy status displayed for it. It now renders as plain text.
- The collector's state file could fall back to the shared,
  world-writable `/tmp` and used a predictable temp-file name without
  verifying ownership or refusing to follow symlinks — another local
  user could plant a symlink there to have the collector overwrite an
  arbitrary file, or spoof what's displayed. It now requires (creating
  if needed) a verified, user-owned runtime directory, and writes
  atomically with `O_EXCL`/`O_NOFOLLOW` and `0600` permissions.
- SSH/Kamal/git calls to a remote destination had no timeout or output
  cap — a hung or hostile endpoint could stall a poll cycle indefinitely
  or exhaust memory. These now run under a hard wall-clock deadline
  (30s) with a bounded output size (1MB/stream), killing the whole
  process group (not just the direct child) if either limit is hit — a
  destination that trips this shows the same "unreachable" state as any
  other failed check, not a stuck "checking" placeholder.
- Every GitHub Action across CI and the release workflow referenced a
  third party by mutable tag instead of a pinned commit — all of them
  are now pinned to a reviewed, full-length SHA.

## [0.1.1] - 2026-09-06

### Fixed

- CI/deploy status no longer gets stuck on a placeholder "checking" state
  forever for a project whose GitHub repository was renamed — the
  collector now follows the redirect GitHub's API returns for the old
  name instead of treating it as a hard failure.

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
