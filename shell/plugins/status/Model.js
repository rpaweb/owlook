// Pure parsing/formatting helpers for the state file the collector writes.
// No QML dependencies here so this can be unit tested with plain node/mjs
// the same way Omarchy's own first-party widgets test their Model.js files.

var BAD_STATES = {
  failure: true, timed_out: true, action_required: true, cancelled: true,
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

// "no_runs" rows exist so a project with no Actions runs yet still gets a
// tab (see Collector#poll_project_ci) — but they're not a check that ran,
// so they don't count as one. Used both for the bar tooltip's "N check(s)
// passing" and for the CI section's own tracked-branch count below.
function isRealCheck(entry) {
  return entry.state !== "no_runs"
}

function realCheckCount(entries) {
  return entries.filter(isRealCheck).length
}

function barText(entries) {
  if (entries.length === 0) return "🦉"
  var bad = badCount(entries)
  return bad > 0 ? "🦉 " + bad : "🦉"
}

function stateLabel(state) {
  switch (String(state || "")) {
    case "success": return "passing"
    case "failure": return "failing"
    case "cancelled": return "cancelled"
    case "timed_out": return "timed out"
    case "action_required": return "action required"
    case "in_progress": return "running"
    case "queued": return "queued"
    case "waiting": return "waiting"
    case "ok": return "ok"
    case "failing": return "failing"
    case "unreachable": return "unreachable"
    case "no_runs": return "no runs yet"
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
    case "in_progress": return "RUN"
    case "queued": return "QUE"
    case "no_runs": return "NONE"
    default: return "?"
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
// message QUEUES already shows for zero destinations.
function ciRunRows(ciList) {
  return (ciList || []).filter(isRealCheck)
}

// Short label for a destination's badge: the failed count normally, or
// "unreachable" when the check itself couldn't run (see
// Collector#poll_destination_queue — that state means "SSH/exec failed",
// not "zero failures").
function destBadgeLabel(entry) {
  if (!entry) return ""
  if (entry.state === "unreachable") return "unreachable"
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
  if (!entry || entry.state === "unreachable") return []
  var d = entry.details || {}
  var stats = []
  if (d.workers !== undefined) {
    stats.push({ n: String(d.workers), l: "workers", warn: d.workers === 0 })
  }
  if (d.ready !== undefined && d.ready > 0 && d.oldest !== undefined) {
    stats.push({ n: String(d.oldest), l: "oldest", warn: false })
  }
  if (d.ready !== undefined) {
    stats.push({ n: String(d.ready), l: "ready", warn: false })
  }
  return stats
}

// The last path segment of "owner/repo" — what a tab shows. The owner is
// still there in the project-name line inside the tab's own content; the
// tab strip itself is tight on space and every project here is already
// disambiguated by which tab it's on.
function shortProjectName(project) {
  var parts = String(project || "").split("/")
  return parts[parts.length - 1] || String(project || "")
}

// "1 project" / "5 projects" — PanelHero uppercases this itself.
function projectCountLabel(count) {
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
      projects[name] = { project: name, ci: [], destinationsByName: {}, destinationOrder: [] }
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
    }
  })

  return order.map(function(name) {
    var group = projects[name]
    return {
      project: group.project,
      ci: group.ci,
      destinations: group.destinationOrder.slice().sort().map(function(d) { return group.destinationsByName[d] })
    }
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    parseEntries: parseEntries,
    isBad: isBad,
    anyBad: anyBad,
    badCount: badCount,
    isRealCheck: isRealCheck,
    realCheckCount: realCheckCount,
    barText: barText,
    stateLabel: stateLabel,
    rowLocation: rowLocation,
    queueShortText: queueShortText,
    queueErrorDetail: queueErrorDetail,
    ciSummary: ciSummary,
    ciBadgeLabel: ciBadgeLabel,
    trackedLabel: trackedLabel,
    ciRunRows: ciRunRows,
    destBadgeLabel: destBadgeLabel,
    destStats: destStats,
    shortProjectName: shortProjectName,
    projectIsBad: projectIsBad,
    projectCountLabel: projectCountLabel,
    relativeTime: relativeTime,
    groupByProject: groupByProject
  }
}
