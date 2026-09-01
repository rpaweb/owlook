import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Reads $XDG_RUNTIME_DIR/owlook.json (written by the owlook collector) via
// FileView with watchChanges: true — no polling, no process spawned by this
// widget. See Owlook::StateWriter for the write side.
//
// Layout: one tab per project (a fixed-size 340×456 panel doesn't have room
// to show every project's CI and queues at once — see the design notes in
// the mockup this was ported from). Below the tab strip, CI and QUEUES are
// two independently-scrolling regions rather than one growing panel: CI has
// a fixed height, QUEUES fills whatever's left down to the bottom edge. The
// panel's outer size never changes, no matter which tab is open or how much
// a project has to show — only the two inner regions scroll.
Panel {
  id: root
  moduleName: "owlook.status"
  manageIpc: false

  property var anchorItem: null
  property int activeTabIndex: 0
  property bool showingSettings: false

  // "All branches" persists into Omarchy's shared shell.json (the same
  // file the bar's own layout editor writes to) rather than a second
  // settings channel between this process and the collector's — see
  // Owlook::WidgetSettings, which reads the identical entry.
  function toggleAllBranchesSetting() {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.allBranches = !root.setting("allBranches", false)

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string statePath: runtimeDir + "/owlook.json"

  property var entries: []

  readonly property var projects: Model.groupByProject(root.entries)
  // Clamped rather than trusted as-is: if a project disappears from the
  // config between polls, a stale index would otherwise point past the end
  // of a shorter list.
  readonly property int activeIndex: projects.length === 0 ? 0
    : Math.max(0, Math.min(root.activeTabIndex, projects.length - 1))
  readonly property var activeProject: projects.length > 0 ? projects[root.activeIndex] : null

  readonly property bool alarming: Model.anyBad(entries)
  readonly property bool loading: Model.anyLoading(entries)

  function barText() { return Model.barText(entries) }
  function badgeText() { return Model.badgeText(entries) }

  function tooltipText() {
    if (entries.length === 0) return "Owlook — waiting for the collector"
    // entries counts rows (ci + queue + deploy), not distinct projects — a
    // single project with two failing destinations is 2 rows, not 2
    // projects, so "check(s)" rather than "project(s)". A "no_runs" row
    // (a project with no Actions runs yet) isn't a check that ran, so it's
    // excluded here the same way it's excluded from a tab's "N tracked".
    var bad = Model.badCount(entries)
    return bad > 0 ? bad + " check(s) need attention" : Model.realCheckCount(entries) + " check(s) passing"
  }

  function applyState(raw) {
    root.entries = Model.parseEntries(raw)
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyState(text())
    onFileChanged: reload()
    onLoadFailed: root.entries = []
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Fixed, not content-fitted: this is the one dimension in the whole
    // panel that's non-negotiable, by design — see the mockup notes on
    // why a size that changes per-tab or per-project reads as broken.
    // cappedContentHeight still shrinks it on a genuinely too-small
    // screen; it just never grows past 456 or shrinks for a quiet tab.
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.cappedContentHeight(Style.space(456))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: header
        width: parent.width
        spacing: Style.space(10)

        Item {
          id: heroBlock
          width: parent.width
          implicitHeight: hero.implicitHeight

          property bool settingsOpen: root.showingSettings
          function toggleSettings() { root.showingSettings = !root.showingSettings }

          PanelHero {
            id: hero
            width: parent.width
            title: "OWLOOK"
            meta: Model.projectCountLabel(root.projects.length)
            foreground: root.barForeground
            fontFamily: Style.font.family

            iconComponent: Component {
              OwlIcon {
                implicitWidth: Style.font.display
                implicitHeight: Style.font.display
              }
            }

            // heroBlock, not root: a Component assigned to trailingControl
            // is instantiated inside PanelHero's own item tree, where an
            // unqualified `root` resolves to PanelHero's *own* internal
            // `id: root` rather than this file's — the same gotcha the
            // tailscale/dropbox panels work around by reaching through a
            // distinctly-named sibling instead.
            trailingControl: Component {
              PanelActionButton {
                iconText: "⚙"
                tooltipText: heroBlock.settingsOpen ? "Back" : "Settings"
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                onClicked: heroBlock.toggleSettings()
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.barForeground
        }

        Text {
          visible: !root.showingSettings && root.entries.length === 0
          width: parent.width
          text: "No data yet — is the collector running?"
          color: Qt.darker(root.barForeground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // One tab per project. Scrolls horizontally instead of the panel
        // growing wider — a thin, always-visible scrollbar (not hover-only)
        // is the discoverability cue that there's more to the right; a bare
        // scroll strip with no cue reads as "that's everything".
        ListView {
          id: tabsList
          visible: !root.showingSettings && root.projects.length > 0
          width: parent.width
          height: visible ? implicitHeight : 0
          implicitHeight: Style.space(26)
          orientation: ListView.Horizontal
          spacing: Style.space(4)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentWidth > width

          ScrollBar.horizontal: ScrollBar {
            policy: ScrollBar.AsNeeded
            height: Style.space(3)
          }

          model: root.projects
          delegate: ProjectTab {}
        }
      }

      // The active project's CI + QUEUES, filling everything below the
      // header down to the panel's bottom edge.
      Item {
        id: body
        visible: !root.showingSettings && root.activeProject !== null
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        Text {
          id: projectNameText
          anchors.top: parent.top
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.activeProject ? root.activeProject.project : ""
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        // CI: fixed height, its own scroll — a project tracking six
        // branches doesn't push QUEUES off-screen, it just gets a scrollbar.
        Item {
          id: ciSection
          anchors.top: projectNameText.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(88)

          // "no_runs" rows exist so the project keeps its tab (see
          // Collector#poll_project_ci) but they're not a branch that runs
          // CI, so they're filtered out here — "N tracked" counts branches
          // that actually have CI, same as QUEUES counts destinations
          // that actually exist. "checking" rows stay in (see
          // Model.ciRunRows), so this count is stable through the loading
          // spinner instead of starting at 0.
          readonly property var rows: Model.ciRunRows(root.activeProject ? root.activeProject.ci : [])
          readonly property bool loading: Model.ciLoading(root.activeProject ? root.activeProject.ci : [])

          PanelSectionHeader {
            id: ciHeader
            anchors.top: parent.top
            // The timing suffix is withheld while loading, not just left
            // to read whatever's on disk — otherwise a duration from the
            // *previous* cycle would sit right next to a spinner saying
            // this one isn't done yet.
            text: "CI — " + Model.trackedLabel(ciSection.rows.length)
              + (ciSection.loading ? "" : Model.timingSuffix(root.activeProject ? root.activeProject.ciTiming : null))
            foreground: root.barForeground
          }

          Text {
            visible: !ciSection.loading && ciSection.rows.length === 0
            anchors.top: ciHeader.bottom
            anchors.topMargin: Style.space(6)
            width: parent.width
            text: "no CI runs found"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.italic: true
          }

          Item {
            visible: ciSection.loading
            anchors.top: ciHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom

            LoadingSpinner {
              anchors.centerIn: parent
              foreground: Color.accent
              running: parent.visible
            }
          }

          ListView {
            visible: !ciSection.loading && ciSection.rows.length > 0
            anchors.top: ciHeader.bottom
            anchors.topMargin: Style.space(4)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(6)
            model: ciSection.rows
            delegate: CiRow {}

            ScrollBar.vertical: ScrollBar {
              policy: ScrollBar.AsNeeded
              width: Style.space(3)
            }
          }
        }

        // QUEUES: everything left over, down to the bottom edge. Deploy
        // status has no row of its own here — nothing in v1 produces a
        // "deploy" observation (see Collector), so there's nothing real to
        // show yet; adding a permanent placeholder for it would just be
        // noise until Kamal hooks land.
        Item {
          id: queuesSection
          anchors.top: ciSection.bottom
          anchors.topMargin: Style.space(20)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom

          readonly property var destinations: root.activeProject ? root.activeProject.destinations : []
          readonly property int destCount: destinations.length
          // All-or-nothing: while any destination's queue check hasn't
          // resolved yet (no observation at all, or the "checking"
          // placeholder — see Collector#announce_new_destinations), show
          // one spinner instead of the list, rather than real rows mixed
          // in with rows still waiting.
          readonly property bool loading: Model.destinationsLoading(queuesSection.destinations)

          PanelSectionHeader {
            id: queuesHeader
            anchors.top: parent.top
            text: "QUEUES — " + Model.trackedLabel(queuesSection.destCount)
              + (queuesSection.loading ? "" : Model.timingSuffix(root.activeProject ? root.activeProject.queueTiming : null))
            foreground: root.barForeground
          }

          Text {
            visible: queuesSection.destCount === 0
            anchors.top: queuesHeader.bottom
            anchors.topMargin: Style.space(6)
            width: parent.width
            text: "no Kamal destinations configured"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.italic: true
          }

          Item {
            visible: queuesSection.destCount > 0 && queuesSection.loading
            anchors.top: queuesHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom

            LoadingSpinner {
              anchors.centerIn: parent
              foreground: Color.accent
              running: parent.visible
            }
          }

          ListView {
            visible: queuesSection.destCount > 0 && !queuesSection.loading
            anchors.top: queuesHeader.bottom
            anchors.topMargin: Style.space(4)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(6)
            model: queuesSection.destinations
            delegate: DestRow {}

            ScrollBar.vertical: ScrollBar {
              policy: ScrollBar.AsNeeded
              width: Style.space(3)
            }
          }
        }
      }

      // Settings — opened via the gear icon in the hero, currently a
      // single toggle. Swaps into the same fixed space tabs+body use
      // rather than adding a new region, so the panel's outer size stays
      // untouched by how many settings this grows to later. Plain Column,
      // not scrollable yet: one row fits the body's height with room to
      // spare — worth revisiting once a second or third setting lands.
      Column {
        id: settingsView
        visible: root.showingSettings
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "SETTINGS"
          foreground: root.barForeground
        }

        Toggle {
          width: parent.width
          label: "All branches"
          description: "Track every branch with a recent CI run, dependabot included — not just the ones tied to an environment (master, staging, …)."
          checked: root.setting("allBranches", false)
          foreground: root.barForeground
          accent: Color.accent
          fontFamily: Style.font.family
          onClicked: root.toggleAllBranchesSetting()
        }
      }
    }
  }

  // ---- tab strip delegate --------------------------------------------

  component ProjectTab: Item {
    id: tabItem
    required property var modelData
    required property int index

    readonly property bool active: index === root.activeIndex
    readonly property bool bad: Model.projectIsBad(tabItem.modelData)

    width: tabRow.implicitWidth + Style.space(20)
    height: ListView.view ? ListView.view.height : implicitHeight
    implicitHeight: Style.space(26)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: tabItem.active ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14) : "transparent"
      border.width: tabItem.active ? Style.normalBorderWidth : 0
      border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
    }

    Row {
      id: tabRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Rectangle {
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: tabItem.bad ? root.urgent : Color.muted
      }

      Text {
        text: Model.shortProjectName(tabItem.modelData.project)
        color: tabItem.active ? root.barForeground : Qt.darker(root.barForeground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.activeTabIndex = tabItem.index
    }
  }

  // ---- CI row ----------------------------------------------------------

  component CiRow: Item {
    id: ciRow
    required property var modelData

    readonly property bool bad: Model.isBad(ciRow.modelData.state)
    readonly property string verdictKind: Model.ciVerdictIcon(ciRow.modelData.state) || ""

    width: ListView.view ? ListView.view.width : 0
    implicitHeight: Math.max(ciPill.height, ciText.implicitHeight)

    // Fixed width so PASS/FAIL/RUN/… all line up — a pill that grows or
    // shrinks per row was the exact thing this was built to avoid.
    Rectangle {
      id: ciPill
      width: Style.space(44)
      height: ciPillContent.implicitHeight + Style.space(4)
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      radius: Style.cornerRadius
      color: ciRow.bad
        ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.16)
        : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.08)

      Row {
        id: ciPillContent
        anchors.centerIn: parent
        spacing: Style.space(3)

        // Vector-drawn, not a Unicode ✓/✗ — a font glyph at this size
        // renders inconsistently across fallback chains (weight, baseline,
        // sometimes an emoji-color substitution that ignores this color
        // entirely). Same technique as the loading spinner: an exact
        // shape, always.
        VerdictIcon {
          anchors.verticalCenter: parent.verticalCenter
          visible: ciRow.verdictKind !== ""
          kind: ciRow.verdictKind
          strokeColor: ciRow.bad ? root.urgent : Qt.darker(root.barForeground, 1.15)
        }

        Text {
          id: ciPillText
          anchors.verticalCenter: parent.verticalCenter
          text: Model.ciBadgeLabel(ciRow.modelData.state)
          color: ciRow.bad ? root.urgent : Qt.darker(root.barForeground, 1.15)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    // A dependabot-style branch (several "/"-separated segments plus a
    // version suffix) can easily be longer than the panel is wide. Eliding
    // the branch+summary as one string hid whichever came second — usually
    // the summary, since the branch name always comes first — so a long
    // branch meant never seeing the CI result at all. Horizontal overflow
    // instead: nothing is cut, the row pans (drag, or the scrollbar below)
    // to reach whatever doesn't fit.
    Flickable {
      id: ciTextFlick
      anchors.left: ciPill.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: ciText.implicitHeight
      contentWidth: ciText.implicitWidth
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.HorizontalFlick

      Text {
        id: ciText
        textFormat: Text.StyledText
        text: "<b>" + ciRow.modelData.branch + "</b>  ·  " + Model.ciSummary(ciRow.modelData)
        color: ciRow.bad ? root.urgent : Qt.darker(root.barForeground, 1.15)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      ScrollBar.horizontal: ScrollBar {
        policy: ciTextFlick.contentWidth > ciTextFlick.width ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        height: Style.space(3)
      }
    }
  }

  // ---- CI verdict icon (check / x) --------------------------------------

  // Two strokes, drawn with Shape/ShapePath like the loading spinner —
  // deliberately not a Unicode ✓/✗ glyph. Only ever shown for a resolved
  // verdict (kind is "" otherwise, see Model.ciVerdictIcon); nothing here
  // implies a result for a branch that's still running or hasn't reported.
  component VerdictIcon: Item {
    id: vIcon
    property string kind: ""
    property color strokeColor: Color.foreground

    // Coordinates ported exactly from the approved mockup SVG (viewBox
    // 0 0 24 24: check "4,13 9,18 20,6", X "4,4 20,20" / "20,4 4,20") —
    // fractions of a 24-unit box, so the shape matches what got signed
    // off there, not a fresh guess at the same idea.
    implicitWidth: Style.space(10)
    implicitHeight: Style.space(10)

    Shape {
      anchors.fill: parent
      visible: vIcon.kind === "check"
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: Style.space(1.6)
        strokeColor: vIcon.strokeColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin

        startX: vIcon.width * (4 / 24)
        startY: vIcon.height * (13 / 24)
        PathLine { x: vIcon.width * (9 / 24); y: vIcon.height * (18 / 24) }
        PathLine { x: vIcon.width * (20 / 24); y: vIcon.height * (6 / 24) }
      }
    }

    Shape {
      anchors.fill: parent
      visible: vIcon.kind === "x"
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: Style.space(1.6)
        strokeColor: vIcon.strokeColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        startX: vIcon.width * (4 / 24); startY: vIcon.height * (4 / 24)
        PathLine { x: vIcon.width * (20 / 24); y: vIcon.height * (20 / 24) }
      }
      ShapePath {
        strokeWidth: Style.space(1.6)
        strokeColor: vIcon.strokeColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        startX: vIcon.width * (20 / 24); startY: vIcon.height * (4 / 24)
        PathLine { x: vIcon.width * (4 / 24); y: vIcon.height * (20 / 24) }
      }
    }
  }

  // ---- destination (queue) row -----------------------------------------

  component DestRow: Item {
    id: destRow
    required property var modelData

    readonly property var queueEntry: destRow.modelData.queue
    readonly property bool bad: destRow.queueEntry ? Model.isBad(destRow.queueEntry.state) : false
    readonly property bool checking: destRow.queueEntry !== null && destRow.queueEntry.state === "checking"
    readonly property var stats: Model.destStats(destRow.queueEntry)

    width: ListView.view ? ListView.view.width : 0
    implicitHeight: destBg.height

    Rectangle {
      id: destBg
      width: parent.width
      height: destContent.implicitHeight + Style.space(18)
      radius: Style.cornerRadius
      color: destRow.bad
        ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12)
        : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.05)

      Rectangle {
        // Left accent bar — the same severity cue as the pill, at a glance
        // even when the row is scrolled so its badge text is cut off.
        width: Style.space(3)
        height: parent.height
        radius: Style.cornerRadius
        color: destRow.bad ? root.urgent : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.3)
      }

      Column {
        id: destContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(9)
        spacing: Style.space(6)

        Item {
          width: parent.width
          height: Math.max(destName.implicitHeight, destBadge.height)

          Text {
            id: destName
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: destRow.modelData.destination
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Rectangle {
            id: destBadge
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.cornerRadius
            width: destBadgeText.implicitWidth + Style.space(10)
            height: destBadgeText.implicitHeight + Style.space(4)
            color: destRow.bad
              ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.2)
              : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.1)

            Text {
              id: destBadgeText
              anchors.centerIn: parent
              text: Model.destBadgeLabel(destRow.queueEntry)
              // Not bold, italic instead — a provisional status message
              // ("checking…"), not a result, same visual language as the
              // "no CI runs found" / "no Kamal destinations configured"
              // messages elsewhere in this panel.
              color: destRow.bad ? root.urgent : Qt.darker(root.barForeground, destRow.checking ? 1.6 : 1.15)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: !destRow.checking
              font.italic: destRow.checking
            }
          }
        }

        Row {
          visible: destRow.stats.length > 0
          width: parent.width
          spacing: Style.space(12)

          Repeater {
            model: destRow.stats

            Row {
              id: statChip
              required property var modelData
              spacing: Style.space(3)

              Text {
                id: statValue
                text: statChip.modelData.n
                color: statChip.modelData.warn ? root.urgent : Qt.darker(root.barForeground, 1.1)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                text: statChip.modelData.l
                color: Qt.darker(root.barForeground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.caption * 0.9)
                anchors.baseline: statValue.baseline
              }
            }
          }
        }
      }

      MouseArea {
        id: destHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        enabled: destRow.queueEntry !== null && destRow.queueEntry.state === "unreachable"
      }

      PanelToolTip {
        visible: destHover.enabled && destHover.containsMouse
        text: destRow.queueEntry ? Model.queueErrorDetail(destRow.queueEntry) : ""
      }
    }
  }

  // LoadingSpinner used to be defined inline here — now its own file
  // (LoadingSpinner.qml, same directory), reused from BarWidget.qml too.
}
