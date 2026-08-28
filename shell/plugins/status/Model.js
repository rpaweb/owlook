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

// "check" (✓/✗/…) rather than a specific glyph codepoint from Omarchy's
// icon font, which isn't verified to exist — these are plain Unicode and
// render with any font's fallback chain.
function ciIcon(state) {
  if (isBad(state)) return "✗"
  if (state === "success" || state === "ok") return "✓"
  return "…"
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
    barText: barText,
    stateLabel: stateLabel,
    rowLocation: rowLocation,
    queueShortText: queueShortText,
    queueErrorDetail: queueErrorDetail,
    ciIcon: ciIcon,
    ciSummary: ciSummary,
    relativeTime: relativeTime,
    groupByProject: groupByProject
  }
}
