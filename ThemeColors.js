.pragma library

// Omarchy's own Color singleton (qs.Commons) exposes foreground/
// background/accent/urgent/muted — no success/warn role. Every stock
// theme's colors.toml *does* define "green" and "yellow" (confirmed
// against all 22 shipped themes, github.com/basecamp/omarchy/themes)
// even though Color.qml itself never reads them — it only pulls
// foreground/background/accent/muted/red out of that same file. Parsing
// it again here, the same way Color.qml's own loadColors does, gets a
// real theme-matched success/warn pair without waiting on an upstream
// Color role that doesn't exist yet, and without hardcoding one theme's
// literal hex the way the status dot used to (see ThemeColors.qml).
function parseThemeColors(raw) {
  var colors = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*(green|yellow)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (!match) continue
    colors[match[1]] = match[2]
  }
  return colors
}
