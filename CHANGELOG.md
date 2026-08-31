# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [SemVer](https://semver.org/) — under `0.x`, a MINOR bump signals
"expect breaking changes," a PATCH bump is a fix to what's already released.

## [0.1.0] — 2026-08-31

First release. One systemd `--user` collector process, watching GitHub
Actions, Kamal deploy destinations, and Solid Queue background-job health
across multiple Rails projects, surfaced as a bar widget in Omarchy
(Quattro).

- GitHub Actions status per project, branches auto-detected from local
  `.github/workflows/*.yml` (an "all branches" broad mode is available as
  a setting).
- Solid Queue health (backlog, dead jobs, active workers, oldest-waiting
  age) per Kamal destination, over the same SSH access `kamal deploy`
  already uses.
- Desktop notifications on real state transitions only.
- A 340×456 bar panel, one tab per project, with its own logo mark.
