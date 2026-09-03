// Pure parsing/formatting helpers for the state file the collector writes.
// No QML dependencies here so this can be unit tested with plain node/mjs
// the same way Omarchy's own first-party widgets test their Model.js files.

// GitHub's real conclusion values (confirmed against the Checks/Actions
// API docs, not guessed) — startup_failure specifically caught live: a
// workflow that can't even start (a bad workflow file, most often)
// landed here as neither pass nor fail, showing "?" with no color and
// no verdict icon, and never counted as bad for a desktop notification
// either (see Observation::BAD_STATES, kept in sync by hand with this).
// neutral/skipped/stale are real values too, deliberately left out of
// this set — none of them mean the code is broken.
var BAD_STATES = {
  failure: true, timed_out: true, action_required: true, cancelled: true,
  startup_failure: true,
  failing: true, unreachable: true
}

function parseEntries(raw) {
  var text = String(raw || "").trim()
  if (text === "") return []
  try {
    var parsed = JSON.parse(text)
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

function isBad(state) {
  return !!BAD_STATES[String(state || "")]
}

function anyBad(entries) {
  return entries.some(function(entry) { return isBad(entry.state) })
}

function badCount(entries) {
  return entries.filter(function(entry) { return isBad(entry.state) }).length
}

// A third tier, deliberately not folded into BAD_STATES — "stalled"
// (Collector#queue_state: ready jobs, zero workers) is concerning, not
// broken. Merging it into isBad would mean it's indistinguishable from
// an actual failure everywhere this panel signals bad (the bar pill's
// dot, the tab strip, the row itself) — the whole reason ThemeColors.warn
// exists is to give it a color of its own instead.
function isStalled(state) {
  return state === "stalled"
}

function anyStalled(entries) {
  // A deploy is never state: "stalled" (that's a queue-only state) — its
  // own "behind" fact lives in details, via deployFreshnessKind. Calling
  // that on a non-deploy entry is harmless: no entry.details.fresh_ref
  // means "unknown", never "stale".
  return entries.some(function(entry) { return isStalled(entry.state) || deployFreshnessKind(entry) === "stale" })
}

// Global (not per-project/per-section, unlike ciLoading/destinationsLoading
// below) — the bar pill's own status dot needs one flat "is anything at all
// still resolving" signal, not a per-tab one. Both CI and queue placeholders
// stamp state: "checking" (see Collector#pending_ci_observation and
// #pending_queue_observation), so this catches either.
function anyLoading(entries) {
  return entries.some(function(entry) { return entry.state === "checking" })
}

// "no_runs" rows exist so a project with no Actions runs yet still gets a
// tab (see Collector#poll_project_ci), "checking" rows exist so a
// branch/destination the collector just discovered shows up before its
// real check completes (see Collector#announce_new_ci_branches /
// #announce_new_destinations), and "ci_timing"/"queue_timing" rows are a
// duration measurement, not a check at all — none of the three counts as
// one. Used both for the bar tooltip's "N check(s) passing" and for the
// CI/QUEUES sections' own tracked counts below.
function isRealCheck(entry) {
  return entry.kind !== "ci_timing" && entry.kind !== "queue_timing" &&
    entry.state !== "no_runs" && entry.state !== "checking"
}

function realCheckCount(entries) {
  return entries.filter(isRealCheck).length
}

function barText(entries) {
  if (entries.length === 0) return "🦉"
  var bad = badCount(entries)
  return bad > 0 ? "🦉 " + bad : "🦉"
}

// The digits-only half of the bar pill — BarWidget.qml pairs this with a
// vector OwlIcon instead of the emoji baked into barText() above (kept
// around only to size the pill; see BarWidget.qml for why).
function badgeText(entries) {
  var bad = badCount(entries)
  return bad > 0 ? String(bad) : ""
}

function stateLabel(state) {
  switch (String(state || "")) {
    case "success": return "passing"
    case "failure": return "failing"
    case "cancelled": return "cancelled"
    case "timed_out": return "timed out"
    case "action_required": return "action required"
    case "startup_failure": return "startup failure"
    case "neutral": return "neutral"
    case "skipped": return "skipped"
    case "stale": return "stale"
    case "in_progress": return "running"
    case "queued": return "queued"
    case "waiting": return "waiting"
    case "ok": return "ok"
    case "failing": return "failing"
    case "unreachable": return "unreachable"
    case "no_runs": return "no runs yet"
    case "checking": return "checking…"
    default: return String(state || "unknown")
  }
}

// A queue row's `details` shape depends on its state: {ready, failed} on
// success, {error} when the check itself failed (see Collector -
// poll_destination_queue records "unreachable" rather than omitting the
// row, so the panel can say why data is missing instead of just not
// showing a destination at all). Kept short — the full error belongs in a
// tooltip, not crammed into the main line.
function queueShortText(entry) {
  if (!entry) return ""
  if (entry.state === "unreachable") return "SSH unreachable"
  var details = entry.details || {}
  return "ready " + (details.ready !== undefined ? details.ready : "?")
    + "  ·  failed " + (details.failed !== undefined ? details.failed : "?")
}

function queueErrorDetail(entry) {
  if (!entry || entry.state !== "unreachable") return ""
  return (entry.details && entry.details.error) || "unknown error"
}

// "3/3", or "2/3 · 1 skipped" when something was skipped — skips don't
// count against the total the way a failure would (matches GitHub's own
// treatment: a run with only skips is still green). Falls back to the
// plain state label when a row predates job counts being recorded.
function ciSummary(entry) {
  var details = entry.details || {}
  if (details.jobs_total === undefined) return stateLabel(entry.state)
  var text = details.jobs_passed + "/" + details.jobs_total
  if (details.jobs_skipped) text += "  ·  " + details.jobs_skipped + " skipped"
  return text
}

// The workflow's own display name (e.g. "07. Checks") — GitHub's "latest
// run for this branch" endpoint doesn't care which workflow produced that
// run, so a repo with more than one workflow triggering on the same
// branch can have this flip between them from one poll to the next.
// "" for a row that predates this being recorded (falsy, same as
// ciSummary's own missing-data fallback).
function ciWorkflowLabel(entry) {
  var details = entry.details || {}
  return details.workflow_name || ""
}

// Fixed-width pill label for a CI row, max 4 chars so every pill in the
// section — pass or fail, running or queued — renders at the same width
// instead of the box growing/shrinking per row.
function ciBadgeLabel(state) {
  switch (String(state || "")) {
    case "success": return "PASS"
    case "failure": return "FAIL"
    case "cancelled": return "CANC"
    case "timed_out": return "TIME"
    case "action_required": return "ACT"
    case "startup_failure": return "STRT"
    case "neutral": return "NTRL"
    case "skipped": return "SKIP"
    case "stale": return "STAL"
    case "in_progress": return "RUN"
    case "queued": return "QUE"
    case "no_runs": return "NONE"
    case "checking": return "…"
    default: return "?"
  }
}

// "check" for a resolved pass, "x" for any resolved fail-ish verdict,
// "dash" for a run that hasn't resolved yet but is actively moving
// (queued or in progress — a real run sits in "queued" for a few
// seconds before GitHub reports "in_progress", confirmed live), null for
// anything else not yet a verdict (no runs, checking, unknown) — a
// checkmark or an X would claim a result that doesn't exist for those.
// Drawn as vector shapes in the widget (see the VerdictIcon component in
// Panel.qml), not a Unicode glyph — ✓/✗/— render inconsistently across
// fonts/fallback chains at pill size.
function ciVerdictIcon(state) {
  switch (String(state || "")) {
    case "success": return "check"
    case "failure":
    case "cancelled":
    case "timed_out":
    case "action_required":
    case "startup_failure":
      return "x"
    case "in_progress":
    case "queued":
      return "dash"
    default: return null
  }
}

// "N tracked" — same wording for both the CI and QUEUES section headers
// (branches tracked, destinations tracked), so the two sections read as
// the same kind of count rather than two different vocabularies.
function trackedLabel(count) {
  return count + " tracked"
}

// A project's CI rows, minus the "no_runs" ones — "N tracked" means N
// branches that actually run CI, not N branches the collector merely
// attempted to poll. A project with only "no_runs" rows renders exactly
// like one with an empty ci list: "0 tracked" and the same empty-state
// message QUEUES already shows for zero destinations. "checking" rows
// are kept in, unlike isRealCheck's stricter filter — the collector
// already knows this branch exists and will report on it, so the count
// (and, via ciLoading below, the fact that a result is still pending)
// should stay stable through the loading spinner rather than starting
// at 0 and jumping once results land.
function ciRunRows(ciList) {
  return (ciList || []).filter(function(entry) { return entry.state !== "no_runs" })
}

// Whether the CI section should show a loading spinner instead of its
// rows — true while any tracked branch hasn't resolved yet. Same
// all-or-nothing principle as destinationsLoading: the section waits for
// every branch to have a real result before showing any of them.
function ciLoading(ciList) {
  return (ciList || []).some(function(entry) { return entry.state === "checking" })
}

// "· 0.9s" once a real duration is known (see Collector#record_timing),
// "" otherwise — no dash, no "0.0s", just nothing to show yet. The caller
// is expected to withhold this while its own section is still loading
// (see Panel.qml), so a stale duration from the previous cycle never
// sits next to a spinner claiming the current one isn't done.
function timingSuffix(timingEntry) {
  if (!timingEntry) return ""
  var seconds = timingEntry.details && timingEntry.details.duration_seconds
  if (seconds === undefined || seconds === null) return ""
  return " · " + seconds + "s"
}

// Short label for a destination's badge: the failed count normally, or
// "unreachable" when the check itself couldn't run (see
// Collector#poll_destination_queue — that state means "SSH/exec failed",
// not "zero failures").
function destBadgeLabel(entry) {
  if (!entry) return ""
  // A destination the collector just discovered but hasn't checked over
  // SSH yet (see Collector#announce_new_destinations) — real, honest
  // state, not "0 failed" (which would claim a result that doesn't exist)
  // and not silence (which reads as "nothing configured here").
  if (entry.state === "checking") return "checking…"
  if (entry.state === "unreachable") return "unreachable"
  // "0 failed" would be technically true and substantively misleading —
  // the actual news here is that nothing's working the backlog at all.
  if (entry.state === "stalled") return "stalled"
  var details = entry.details || {}
  var failed = details.failed !== undefined ? details.failed : "?"
  return failed + " failed"
}

// The stat chips under a destination's name+badge, in a fixed order
// (workers, oldest, ready) — but only the ones the row actually has data
// for, so an older observation recorded before Sources::Queue reported
// workers/oldest still renders cleanly as just a "ready" chip. "oldest"
// is also omitted whenever ready is 0 — with nothing waiting, there's no
// oldest waiting job to report, and a dash there reads as broken rather
// than as "not applicable".
function destStats(entry) {
  if (!entry || entry.state === "unreachable" || entry.state === "checking") return []
  var d = entry.details || {}
  var stats = []
  if (d.workers !== undefined) {
    // Same condition as Collector#queue_state's "stalled" — 0 workers on
    // its own isn't concerning (plenty of setups scale workers to zero
    // when there's nothing to do); it only matters paired with a real
    // backlog waiting on them.
    stats.push({ n: String(d.workers), l: "workers", warn: d.workers === 0 && d.ready > 0 })
  }
  if (d.ready !== undefined && d.ready > 0 && d.oldest !== undefined) {
    stats.push({ n: String(d.oldest), l: "oldest", warn: false })
  }
  if (d.ready !== undefined) {
    stats.push({ n: String(d.ready), l: "ready", warn: false })
  }
  return stats
}

// Short SHA for the DEPLOY block's left side — the standard 7-character
// git abbreviation, not the full 40. Empty until a real check has
// actually landed a version (never during "checking"/"unreachable").
function deployShaLabel(entry) {
  if (!entry || !entry.version) return ""
  return String(entry.version).slice(0, 7)
}

// DEPLOY block's status badge. Unlike the QUEUE badge (always a failed
// count once real data exists), this one has three different sources: a
// provisional state (checking/unreachable, same language as QUEUE's
// own), or — once there's a real result — whether DeployFreshness found
// a match at all. No match isn't a failure (a force-push broke the
// relationship, or the commit just isn't fetched locally yet — see
// DeployFreshness's own comment), so it reads as neutral, not alarming.
function deployBadgeLabel(entry) {
  if (!entry) return ""
  if (entry.state === "checking") return "checking…"
  if (entry.state === "unreachable") return "unreachable"
  var details = entry.details || {}
  if (details.fresh_ref === undefined) return "unmatched"
  return details.behind > 0 ? details.behind + " behind" : "at " + details.fresh_ref
}

// "fresh" (the deployed SHA matches a branch or tag's head exactly),
// "stale" (behind one), or "unknown" (DeployFreshness found no match at
// all). Only meaningful once state is "ok" — checking/unreachable have
// their own treatment already, same as QUEUE's stalled/bad.
function deployFreshnessKind(entry) {
  if (!entry || entry.state !== "ok") return "unknown"
  var details = entry.details || {}
  if (details.fresh_ref === undefined) return "unknown"
  return details.behind > 0 ? "stale" : "fresh"
}

// The last path segment of "owner/repo" — what a tab shows. The owner is
// still there in the project-name line inside the tab's own content; the
// tab strip itself is tight on space and every project here is already
// disambiguated by which tab it's on.
function shortProjectName(project) {
  var parts = String(project || "").split("/")
  return parts[parts.length - 1] || String(project || "")
}

// "1 project" / "5 projects" — PanelHero uppercases this itself. Zero
// reads as "NO PROJECTS" rather than "0 projects" — a real, actionable
// state (see Panel.qml's noProjectsConfigured), not just an edge case of
// the count.
function projectCountLabel(count) {
  if (count === 0) return "no projects"
  return count + (count === 1 ? " project" : " projects")
}

// Whether a project has anything that should turn its tab dot red —
// checked before the tab is even opened, same purpose as the bar pill's
// own alarming state but scoped to one project.
function projectIsBad(group) {
  if (group.ci.some(function(entry) { return isBad(entry.state) })) return true
  return group.destinations.some(function(dest) {
    return (dest.deploy && isBad(dest.deploy.state)) || (dest.queue && isBad(dest.queue.state))
  })
}

// Only ever a queue thing today — nothing in v1 produces a "stalled" CI
// or deploy state (see Collector#queue_state), but this reads group.ci
// the same shape as projectIsBad anyway so it doesn't quietly go stale
// if that changes later.
function projectIsStalled(group) {
  if (group.ci.some(function(entry) { return isStalled(entry.state) })) return true
  return group.destinations.some(function(dest) {
    return (dest.deploy && (isStalled(dest.deploy.state) || deployFreshnessKind(dest.deploy) === "stale")) ||
      (dest.queue && isStalled(dest.queue.state))
  })
}

// Whether the QUEUES section should show a loading spinner instead of
// its rows — true while any destination has no resolved check yet (no
// queue observation at all, or still "checking" — see
// Collector#announce_new_destinations). All-or-nothing: the section
// waits for every destination to have a real result before showing any
// of them, rather than rows trickling in one at a time as each SSH
// check happens to finish.
function destinationsLoading(destinations) {
  return (destinations || []).some(function(dest) {
    return !dest.queue || dest.queue.state === "checking" ||
      !dest.deploy || dest.deploy.state === "checking"
  })
}

// A "ci" row is identified by branch, a "deploy"/"queue" row by destination
// — never both set on the same row (see Ruby's Owlook::Observation#key).
function rowLocation(entry) {
  if (entry.kind === "ci") return entry.branch || "?"
  return entry.destination || "?"
}

function relativeTime(isoString, nowMs) {
  var ts = Date.parse(isoString)
  if (!isFinite(ts)) return "unknown time"
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts) / 1000))
  if (diff < 60) return "just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  return days + "d ago"
}

// Groups the flat row list into one entry per project, with its "ci" rows
// (usually one, per branch) kept separate from its per-destination rows —
// a destination's "deploy" and "queue" observations are two different rows
// in the state file (different sources, different write cadences; see
// Store), but belong together in the UI, so this is where they're joined
// for display. Never merged upstream: Store's whole-row replacement would
// silently drop one source's data if a "deploy" and "queue" observation
// shared a row.
function groupByProject(entries) {
  var projects = {}
  var order = []

  function projectGroup(name) {
    if (!projects[name]) {
      projects[name] = {
        project: name, ci: [], destinationsByName: {}, destinationOrder: [],
        ciTiming: null, queueTiming: null
      }
      order.push(name)
    }
    return projects[name]
  }

  function destinationGroup(group, destination) {
    if (!group.destinationsByName[destination]) {
      group.destinationsByName[destination] = { destination: destination, deploy: null, queue: null }
      group.destinationOrder.push(destination)
    }
    return group.destinationsByName[destination]
  }

  entries.forEach(function(entry) {
    var group = projectGroup(entry.project)
    if (entry.kind === "ci") {
      group.ci.push(entry)
    } else if (entry.kind === "deploy" || entry.kind === "queue") {
      destinationGroup(group, entry.destination)[entry.kind] = entry
    } else if (entry.kind === "ci_timing") {
      group.ciTiming = entry
    } else if (entry.kind === "queue_timing") {
      group.queueTiming = entry
    }
  })

  return order.map(function(name) {
    var group = projects[name]
    return {
      project: group.project,
      ci: group.ci,
      destinations: group.destinationOrder.slice().sort().map(function(d) { return group.destinationsByName[d] }),
      ciTiming: group.ciTiming,
      queueTiming: group.queueTiming
    }
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    parseEntries: parseEntries,
    isBad: isBad,
    anyBad: anyBad,
    anyLoading: anyLoading,
    badCount: badCount,
    isStalled: isStalled,
    anyStalled: anyStalled,
    projectIsStalled: projectIsStalled,
    isRealCheck: isRealCheck,
    realCheckCount: realCheckCount,
    barText: barText,
    badgeText: badgeText,
    stateLabel: stateLabel,
    rowLocation: rowLocation,
    queueShortText: queueShortText,
    queueErrorDetail: queueErrorDetail,
    ciSummary: ciSummary,
    ciWorkflowLabel: ciWorkflowLabel,
    ciBadgeLabel: ciBadgeLabel,
    ciVerdictIcon: ciVerdictIcon,
    trackedLabel: trackedLabel,
    ciRunRows: ciRunRows,
    ciLoading: ciLoading,
    timingSuffix: timingSuffix,
    destBadgeLabel: destBadgeLabel,
    destStats: destStats,
    deployShaLabel: deployShaLabel,
    deployBadgeLabel: deployBadgeLabel,
    deployFreshnessKind: deployFreshnessKind,
    shortProjectName: shortProjectName,
    projectIsBad: projectIsBad,
    destinationsLoading: destinationsLoading,
    projectCountLabel: projectCountLabel,
    relativeTime: relativeTime,
    groupByProject: groupByProject
  }
}
