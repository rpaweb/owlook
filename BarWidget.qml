import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry point. Owns the pill and bar routing; Panel.qml (loaded
// separately, same pattern as akitaonrails/ai-usagebar) owns reading the
// state file and rendering the popup. Also owns running the collector
// itself now — no systemd unit, nothing to install or enable separately;
// this Timer+Process is the whole scheduler. Same real pattern as
// ssandys/galley's Controller.qml (Qt.resolvedUrl + Process), not
// invented here — confirmed by reading that plugin's actual source.
BarWidget {
  id: root
  moduleName: "owlook.status"

  readonly property var panelItem: panelLoader.item

  // Qt.resolvedUrl resolves against *this file's* own location, so this
  // finds the collector wherever the plugin actually got installed
  // (omarchy plugin add clones the whole repo, collector/ included) —
  // never a hardcoded dev-checkout path.
  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) return decodeURIComponent(value.substring(7))
    return value
  }

  readonly property string collectorScript: root.pathFromUrl(Qt.resolvedUrl("collector/bin/owlook-collector"))

  // 30s, not tuned per-kind like the old systemd daemon's separate CI/queue
  // intervals — a single short-lived process re-launched from scratch each
  // time has no in-memory state to carry a second cadence across
  // invocations anyway, so one interval for everything is what's actually
  // simpler here, not just a smaller number. A real full cycle (CI +
  // queue + deploy, several projects) measured live at 33-41s — longer
  // than this interval — so `collectorProcess.running` is checked before
  // ever starting another one; a slow cycle just runs back-to-back with
  // the next, never two at once stepping on the same state file.
  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!collectorProcess.running) collectorProcess.running = true
  }

  Process {
    id: collectorProcess
    command: ["ruby", root.collectorScript]

    stdout: StdioCollector {
      onStreamFinished: if (text !== "") console.log("[owlook collector]", text)
    }
    stderr: StdioCollector {
      onStreamFinished: if (text !== "") console.log("[owlook collector]", text)
    }
  }

  function toggle() {
    if (panelItem) panelItem.toggle()
  }

  // Bar.qml's popout coordinator calls close() on whichever owner it had
  // registered when a different panel takes over (see barWidgetRoot's own
  // comment in Panel.qml for why root, not panelItem, is what gets
  // registered as that owner) — without this, switching from owlook's
  // panel straight to another bar icon's would leave this one still
  // marked open internally, not just visually stuck.
  function close() {
    if (panelItem) panelItem.close()
  }

  function injectPanel() {
    var target = panelItem
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("barWidgetRoot" in target) target.barWidgetRoot = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // WidgetButton only ever renders a single centered Text label — no icon
  // slot — so it keeps doing every bit of interaction (click, hover,
  // tooltip, bar registration) exactly as before. What's new is
  // labelVisible: false, so that text never actually paints; iconHolder
  // below draws the real pill content on top of it, purely decorative
  // (no MouseArea of its own, so clicks/hover still land on the button
  // beneath it untouched). fixedWidth matches a plain icon-only pill —
  // no extra slack for a badge anymore; the status dot is small enough
  // to overlap the icon's own corner (same trick TailscaleIcon uses for
  // its badge) without needing its own reserved space, which was making
  // this pill visibly wider than its neighbors before.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.panelItem ? root.panelItem.barText() : "🦉"
    labelVisible: false
    fixedWidth: Style.font.iconLarge + scaledHorizontalMargin * 2
    active: root.panelItem ? root.panelItem.alarming : false
    tooltipText: root.panelItem ? root.panelItem.tooltipText() : "Owlook"
    horizontalMargin: 8

    onPressed: root.toggle()
  }

  ThemeColors {
    id: themeColors
  }

  Item {
    id: iconHolder
    anchors.centerIn: button
    width: owlIcon.width
    height: owlIcon.height

    OwlIcon {
      id: owlIcon
      // Style.font.iconLarge (18px) — Style.font.icon (14px) turned out
      // barely perceptible over the original button.fontSize (12px, meant
      // for text, not icons); Dropbox/Tailscale's icon.qml components
      // default to Style.font.icon, but they live inside a shared
      // panel/tray, not a standalone single-icon pill like this one, so
      // that precedent doesn't actually transfer. iconLarge is a real
      // Omarchy token too (Menu.qml, PolkitAgent.qml, GalleryPanel.qml
      // all use it), just the one meant for a bigger, standalone icon.
      implicitWidth: Style.font.iconLarge
      implicitHeight: Style.font.iconLarge
      // Bar-pill only: button.foreground (theme-neutral, the same color
      // every other bar icon uses — TailscaleIcon/DropboxIcon are both
      // single-color, matching root.color everywhere), not the fixed
      // amber brand color the panel header and notification icon keep.
      // The pill sits shoulder-to-shoulder with other apps' icons, where
      // standing out read as broken rather than intentional; the panel
      // and notification are owlook's own space, where the brand color
      // earns its keep instead of competing with anything.
      ringColor: button.foreground
      beakColor: button.foreground
    }

    // A plain status dot, like Slack's own tray icon — red/green to
    // evaluate both states live; may end up "nothing at all when OK"
    // instead (matching TailscaleIcon's own badge, which only exists when
    // warning is true) once this is actually settled. Hidden specifically
    // while loading (state: "checking") — without this, the dot showed
    // green the instant a settings toggle or a fresh start put rows in
    // this state, before anything had actually been checked yet.
    Rectangle {
      id: statusDot
      readonly property bool bad: root.panelItem ? root.panelItem.alarming : false
      readonly property bool stalled: root.panelItem ? root.panelItem.stalled : false
      readonly property bool loading: root.panelItem ? root.panelItem.loading : false
      visible: !loading
      // Bigger and closer than the first pass — barely overlapping the
      // icon's corner instead of hanging off it, and not pushed down
      // toward the bar's own bottom edge. Sized/positioned from
      // description (Slack/HEY's own dock badge), not a side-by-side
      // visual comparison — confirm against the real thing.
      width: Math.max(5, Style.font.iconLarge * 0.4)
      height: width
      radius: width / 2
      anchors.right: owlIcon.right
      anchors.bottom: owlIcon.bottom
      anchors.rightMargin: -width * 0.05
      anchors.bottomMargin: 0
      // themeColors.success, not a hardcoded literal — this used to be
      // "#9ece6a" outright, which is Tokyo Night's own green, not a real
      // color choice; see ThemeColors.qml for where it actually comes
      // from now. Three tiers, not two — bad (an actual failure) still
      // wins over stalled (a queue backlog with nobody working it, see
      // Collector#queue_state) if somehow both are true at once.
      color: bad ? Color.urgent : (stalled ? themeColors.warn : themeColors.success)
      border.color: Color.popups.background
      border.width: 1
    }

    // Same slot, same size, while loading — the same spinner technique
    // used everywhere else in this panel (LoadingSpinner.qml, extracted
    // from Panel.qml so this file could reuse it instead of a fresh
    // "still working on it" idea just for this one corner.
    LoadingSpinner {
      visible: root.panelItem ? root.panelItem.loading : false
      anchors.right: owlIcon.right
      anchors.bottom: owlIcon.bottom
      anchors.rightMargin: -statusDot.width * 0.05
      anchors.bottomMargin: 0
      implicitWidth: statusDot.width
      implicitHeight: statusDot.width
      strokeWidth: Math.max(1, statusDot.width * 0.1)
      foreground: button.foreground
      running: visible
    }
  }
}
