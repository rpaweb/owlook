// Pure parsing/formatting helpers for the state file the collector writes.
// No QML dependencies here so this can be unit tested with plain node/mjs
// the same way Omarchy's own first-party widgets test their Model.js files.

var BAD_STATES = { failure: true, timed_out: true, action_required: true, cancelled: true, failing: true }

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
    default: return String(state || "unknown")
  }
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
    relativeTime: relativeTime,
    groupByProject: groupByProject
  }
}
