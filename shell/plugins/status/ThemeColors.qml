import QtQuick
import Quickshell
import Quickshell.Io
import "ThemeColors.js" as ThemeColorsParser

// Reads the same colors.toml Omarchy's Color singleton reads
// (qs.Commons, ~/.local/state/omarchy/current/theme/colors.toml), for
// the two roles it doesn't expose — see ThemeColors.js for why "green"/
// "yellow" are there to read at all. success/warn start at Tokyo
// Night's own values (what the status dot used to hardcode) purely as
// a last-resort fallback for the rare theme missing these keys —
// watchChanges means a live theme switch updates both without a shell
// restart, the same way every other Color-derived value in this panel
// already does.
Item {
  id: root

  readonly property string currentThemePath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme"
  property color success: "#9ece6a"
  property color warn: "#e0af68"

  FileView {
    path: root.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyColors(text())
    onFileChanged: reload()
  }

  function applyColors(raw) {
    var parsed = ThemeColorsParser.parseThemeColors(raw)
    if (parsed.green) root.success = parsed.green
    if (parsed.yellow) root.warn = parsed.yellow
  }
}
