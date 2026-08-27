// Pure parsing/formatting helpers for the state file the collector writes.
// No QML dependencies here so this can be unit tested with plain node/mjs
// the same way Omarchy's own first-party widgets test their Model.js files.

var BAD_STATES = { failure: true, timed_out: true, action_required: true, cancelled: true }

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
    default: return String(state || "unknown")
  }
}

// A "ci" row is identified by branch, a "deploy" row by destination — they
// are never both set (see Ruby's Owlook::Observation#key). Render whichever
// one the row actually has instead of assuming destination.
function rowLocation(entry) {
  if (entry.kind === "deploy") return entry.destination || "?"
  return entry.branch || "?"
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

if (typeof module !== "undefined") {
  module.exports = {
    parseEntries: parseEntries,
    isBad: isBad,
    anyBad: anyBad,
    badCount: badCount,
    barText: barText,
    stateLabel: stateLabel,
    rowLocation: rowLocation,
    relativeTime: relativeTime
  }
}
