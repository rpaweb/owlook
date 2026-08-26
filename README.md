# Owlook

CI, deploy, and background-job status for your Rails projects, surfaced as a
bar widget in Omarchy (Quattro) — one long-lived collector process instead of
alt-tabbing between GitHub, a terminal, and a queue dashboard.

## What it does today

- **One collector process** (`bin/owlook-collector`, installable as a
  systemd `--user` unit) polls every project listed in your config once per
  cycle.
- **GitHub Actions** is the only source implemented so far: for each
  project, it resolves `owner/repo` and the current branch from the local
  git checkout, fetches the latest workflow run for that branch, and records
  its status, conclusion, jobs, and steps.
- State is unified into one row per **project + observed branch**,
  deduplicated so the most recently timestamped observation always wins, and
  written atomically to `$XDG_RUNTIME_DIR/owlook.json` — but **only when it
  actually changes**, so a no-op poll never touches the file.
- A Quattro bar widget (`shell/plugins/status/`) reads that file through
  Quickshell's `FileView` with `watchChanges: true` — no polling on the QML
  side, no process spawned by the widget itself.

## Status / roadmap

Built and covered by tests: config loading, the GitHub Actions source, the
unified store + state writer, the collector loop, and the systemd unit. The
bar widget passes `omarchy plugin validate` and `qmllint`, but hasn't been
installed in a live shell yet — see below before you enable it.

Not built yet:

- **Kamal destinations.** Nothing currently reads `config/deploy.yml`. Until
  a source exists that reports a real Kamal destination, every
  GitHub-sourced row uses the **branch name** as `destination` — it is not a
  real deploy destination. See the comment in `lib/owlook/collector.rb`.
- **Queues** (Solid Queue first; Sidekiq behind the same adapter interface
  later, maybe).
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
  - ~/Work/oss/rubyevents
  - ~/Work/oss/another-project
```

That's the whole file. Everything else is derived: owner/repo and branch
come from each project's local git checkout (`git remote get-url origin`,
`git branch --show-current`); a project without a `github.com` remote is
logged and skipped, not an error.

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

`OWLOOK_POLL_INTERVAL` (seconds, default `30`) and `OWLOOK_CONFIG` (default
`~/.config/owlook/config.yml`) are read from the environment if you need to
override them.

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
