# Owlook

CI, deploy, and background-job status for your Rails projects, surfaced as a
bar widget in Omarchy (Quattro) — one long-lived collector process instead of
alt-tabbing between GitHub, a terminal, and a queue dashboard.

## What it does today

- **One collector process** (`bin/owlook-collector`, installable as a
  systemd `--user` unit) polls every project listed in your config once per
  cycle.
- **GitHub Actions**: for each project, resolves `owner/repo` and the
  current branch from the local git checkout, fetches the latest workflow
  run for that branch, and records its status, conclusion, jobs, and steps.
- **Solid Queue**: for each of a project's Kamal destinations (read from
  `config/deploy*.yml`, filesystem only, no SSH), runs `bin/rails runner`
  inside the *already-running* production container over SSH
  (`kamal app exec --reuse`) and records backlog (`ready` jobs), dead-job
  (`failed` jobs), active-worker (`workers`, processes Solid Queue itself
  still considers alive), and oldest-waiting-job-age (`oldest`, in
  seconds, omitted when nothing's ready) counts. A ready count alone can't
  say whether a queue is busy or stuck — `workers` and `oldest` are what
  turn "60 ready" into either "4 workers chewing through it" or "0
  workers, nothing's processing it at all". Needs zero code added to the
  target Rails app —
  Solid Queue's own model classes already exist — and zero new credentials:
  it reuses whatever SSH access you already have for `kamal deploy` itself
  (same key, same agent — nothing owlook-specific to set up). Runs on its
  own, slower cadence than the GitHub Actions poll: an SSH round-trip isn't
  free the way a GitHub API call is.

  Best-effort, not required: a project with no working SSH access still
  gets CI status from GitHub Actions. When a destination's check fails, the
  row isn't silently dropped — it's recorded with `state: "unreachable"`
  and the real error, so the panel says *why* data is missing instead of
  just not showing that destination. `systemctl --user`'s environment
  doesn't inherit `SSH_AUTH_SOCK` from your desktop session, so
  `Sources::Queue` also falls back to gpg-agent's SSH socket
  (`$XDG_RUNTIME_DIR/gnupg/S.gpg-agent.ssh`, a fixed path, not something
  that needs inheriting) when `SSH_AUTH_SOCK` isn't set. A
  passphrase-protected key still needs to be unlocked in your agent at
  least once (same as for any other use of it) — owlook never touches or
  stores a passphrase.
- State is unified into rows of three disjoint kinds, deduplicated so the
  most recently timestamped observation always wins for its identity, and
  written atomically to `$XDG_RUNTIME_DIR/owlook.json` — but **only when it
  actually changes**, so a no-op poll never touches the file. A `"ci"` row
  is identified by project + branch; `"deploy"` (nothing produces these yet)
  and `"queue"` rows are identified by project + destination — a deploy
  destination and a branch are different things, never the same field. See
  `Owlook::Observation#key`. A destination's `"deploy"` and `"queue"` rows
  stay separate in the state file (different sources, different write
  cadences — merging them into one row would let one source silently
  clobber the other's data) and are joined only for display, by the widget.
- A Quattro bar widget (`shell/plugins/status/`) reads that file through
  Quickshell's `FileView` with `watchChanges: true` — no polling on the QML
  side, no process spawned by the widget itself. The panel is a fixed
  340×456 size, one tab per project — it never grows, no matter how many
  projects or branches you track. Inside a tab, CI and QUEUES are two
  independently-scrolling regions rather than one growing panel: a long
  branch list or destination list scrolls inside its own box instead of
  pushing the other section off-screen.

## Status / roadmap

Built and covered by tests: config loading, the GitHub Actions source, the
Kamal destination reader, the Solid Queue source, the unified store + state
writer, the collector loop, and the systemd unit. The Solid Queue source has
been verified against a real, currently-running multi-role Kamal deployment
(both a staging and a production destination), not just fakes in tests —
that live run is what surfaced the `SSH_AUTH_SOCK` fallback, the
shell-escaping fix, and the multi-role output handling described above. The
bar widget is installed and running in a live Quattro shell, confirmed
visually (bar pill + panel rendering real collector data).

Not built yet:

- **Kamal deploy state.** Nothing produces a `"deploy"`-kind observation —
  that needs Kamal hooks or `kamal app version`, both explicitly out of v1
  scope (see below). Destinations themselves are read (for queue checks),
  just not deploy status.
- Sidekiq, behind the same source interface as Solid Queue — only if it
  turns out to be needed; not planned as a stub.
- **Notifications** on state change.

Explicitly out of scope for v1, not planned as stubs: Kamal hooks / SSH
reconciliation (`kamal app version`), a `.desktop`/launcher generator, any
plugin-authoring SDK or public API, Waybar or Omarchy 3.x support. One gem,
one repo — no sub-gems, no monorepo.

## Requirements

- Omarchy 4.x (Quattro) — this only targets the Quickshell-based shell.
- Ruby, managed by mise. This repo pins `4.0.6` via `.ruby-version`.
- The [`gh`](https://cli.github.com/) CLI, authenticated (`gh auth login`).
  Owlook shells out to `gh auth token` for GitHub API access; it never
  stores a token itself. Falls back to the `GITHUB_TOKEN` env var if `gh`
  isn't available.
- systemd running as your user (`systemctl --user`).

## Configuration

`~/.config/owlook/config.yml`:

```yaml
projects:
  - ~/Work/oss/exampleapp
  - ~/Work/oss/another-project
```

That's the whole file. Everything else is derived: owner/repo and branch
come from each project's local git checkout (`git remote get-url origin`,
`git branch --show-current`); a project without a `github.com` remote is
logged and skipped, not an error. Add or remove projects freely — the
collector re-reads this file on every poll (not just at startup), so a
change takes effect on the next cycle, no `systemctl restart` needed.

## Running the collector

```bash
bundle install
bin/owlook-install-systemd-unit   # renders systemd/owlook.service.erb, installs it, does NOT enable it
systemctl --user daemon-reload
systemctl --user enable --now owlook
systemctl --user status owlook    # confirm it's active; journal shows one log line per project per poll
```

The installer resolves the real Ruby interpreter path (`RbConfig.ruby`) at
install time and bakes it into `ExecStart=` — never a mise shim. If you
change the pinned Ruby version, re-run the installer and
`systemctl --user restart owlook` to pick up the new path.

`OWLOOK_POLL_INTERVAL` (seconds, default `30`, GitHub Actions),
`OWLOOK_QUEUE_POLL_INTERVAL` (seconds, default `60`, Solid Queue — an
estimate, not measured against a real server yet), and `OWLOOK_CONFIG`
(default `~/.config/owlook/config.yml`) are read from the environment if you
need to override them.

## The bar widget

`shell/plugins/status/` is a standard Omarchy shell plugin (manifest +
`BarWidget.qml` + `Panel.qml` + `Model.js`). It isn't published anywhere
yet, so `omarchy plugin add` (which clones a git URL) doesn't apply — until
this repo has a remote, install it by hand:

```bash
cp -r shell/plugins/status ~/.config/omarchy/plugins/owlook.status
omarchy plugin validate ~/.config/omarchy/plugins/owlook.status
omarchy plugin enable owlook.status
```

Installing or enabling anything in the live Quattro shell runs arbitrary
code inside your long-lived `omarchy-shell` process — read the plugin before
you enable it, same as Omarchy's own warning for third-party plugins.

## Development

```bash
bundle exec rake test              # full suite, no network access needed
bin/owlook-github-status <path>    # manual check against the real GitHub API for one project
```

Built test-first throughout: every `lib/owlook/*` class has a corresponding
`test/owlook/*_test.rb`. `Sources::GitHub` takes an injected HTTP client so
its tests never touch the network; `GithubClient` itself (the real
`Net::HTTP` transport) is only exercised manually, against real repos, via
`bin/owlook-github-status`.

## License

MIT.
