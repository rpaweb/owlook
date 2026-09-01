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
  // The bar's own module slot holds BarWidget.qml's root, not this file's
  // — Panel.qml only ever loads as a child Loader inside it (see
  // BarWidget.qml). Bar.qml's open-panel underline compares
  // activePopout (set from KeyboardPanel's owner, below) against that
  // slot's own activeItem, so owner has to be the BarWidget root for the
  // match to ever succeed — self-referencing here (the bug this fixes)
  // meant the two could never be equal, and the indicator never showed.
  // Defaults to root so nothing breaks before BarWidget.qml's
  // injectPanel() sets the real one.
  property var barWidgetRoot: root
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
  // The collector's own default (see bin/owlook-collector's OWLOOK_CONFIG
  // fallback) — not read from anywhere live, since a systemd unit's
  // environment isn't something this widget process can see. Right for
  // the common case; a machine overriding OWLOOK_CONFIG for the service
  // would need to edit the actual path by hand instead of via this
  // shortcut.
  readonly property string configPath: (Quickshell.env("HOME") || "") + "/.config/owlook/config.yml"

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
  readonly property bool stalled: Model.anyStalled(entries)

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

  // Own instance, same as BarWidget.qml's — each just reads the same
  // small local colors.toml independently rather than one being threaded
  // down through injectPanel, matching how OwlIcon/LoadingSpinner are
  // already used (a plain reusable component, not a shared singleton).
  ThemeColors {
    id: themeColors
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barWidgetRoot
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
            text: "ENVIRONMENTS — " + Model.trackedLabel(queuesSection.destCount)
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

      // Settings — opened via the gear icon in the hero. Swaps into the
      // same fixed space tabs+body use rather than adding a new region,
      // so the panel's outer size stays untouched by how many settings
      // this grows to later. Two fixed zones, not one flowing Column:
      // toggles up top in their own scrollable area (room to grow past
      // one without the whole panel reflowing), config access pinned to
      // the bottom below a separator — a destination, not a setting,
      // reads as a different kind of row and earns its own place.
      Item {
        id: settingsView
        visible: root.showingSettings
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        Item {
          id: togglesZone
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: settingsBottomSeparator.top
          anchors.bottomMargin: Style.space(10)

          PanelSectionHeader {
            id: settingsHeader
            text: "SETTINGS"
            foreground: root.barForeground
          }

          // Flickable, not a plain Column — clips and scrolls once real
          // content outgrows the space instead of pushing the config row
          // below off the panel. One toggle today, but the room is
          // already there for however many more land later.
          Flickable {
            id: togglesScroll
            anchors.top: settingsHeader.bottom
            anchors.topMargin: Style.space(10)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: width
            contentHeight: togglesColumn.implicitHeight

            Column {
              id: togglesColumn
              width: parent.width
              spacing: Style.space(10)

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

            ScrollBar.vertical: ScrollBar {
              policy: ScrollBar.AsNeeded
              width: Style.space(3)
            }
          }
        }

        Rectangle {
          id: settingsBottomSeparator
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: configRow.top
          anchors.bottomMargin: Style.space(6)
          height: 1
          color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.15)
        }

        // Quick access to config.yml, not an in-panel form to add/remove
        // projects — omarchy-launch-editor already opens whatever editor
        // the user has configured (GUI or terminal, wrapped in a floating
        // terminal for the latter), so this is one exec call instead of
        // reimplementing project management as a second UI. Pinned to
        // the bottom, below the separator — a destination you jump out
        // to, not one more toggle in the scrollable list above.
        Item {
          id: configRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Math.max(44, configRowContent.implicitHeight + Style.space(16))

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: configMouse.containsMouse
              ? Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.08)
              : "transparent"
          }

          // Same shape as the Toggle row above: label+description Column
          // (width = whatever's left after the control) and the control
          // itself, side by side in a Row, both centered on the row as a
          // whole — not the switch, an OpenIcon standing in for it.
          Row {
            id: configRowContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(10)

            Column {
              width: parent.width - openIndicator.width - parent.spacing
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                text: "Edit tracked projects"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Text {
                width: parent.width
                text: "Opens config.yml in your default editor — add or remove repositories there."
                color: Qt.darker(root.barForeground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            OpenIcon {
              id: openIndicator
              anchors.verticalCenter: parent.verticalCenter
              implicitWidth: Style.space(20)
              implicitHeight: Style.space(20)
              strokeColor: Qt.darker(root.barForeground, 1.3)
            }
          }

          MouseArea {
            id: configMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Quickshell.execDetached(["omarchy-launch-editor", root.configPath])
          }
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
    readonly property bool stalled: Model.projectIsStalled(tabItem.modelData)

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
        color: tabItem.bad ? root.urgent : (tabItem.stalled ? themeColors.warn : Color.muted)
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
    readonly property string workflowLabel: Model.ciWorkflowLabel(ciRow.modelData)

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
        // branch · N/N jobs stays exactly where it was — the workflow name
        // rides after it, not between, so the pass/fail summary is still
        // the first thing next to the branch.
        text: "<b>" + ciRow.modelData.branch + "</b>  ·  " + Model.ciSummary(ciRow.modelData)
          + (ciRow.workflowLabel !== "" ? "  ·  " + ciRow.workflowLabel : "")
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

  // The standard "opens something external" mark — an open box with an
  // arrow escaping its top-right corner. Same stroke technique as
  // VerdictIcon: straight PathLines only, no curves, fractions of a
  // 24-unit box so it stays crisp at any size.
  component OpenIcon: Item {
    id: openIcon
    property color strokeColor: Color.foreground

    implicitWidth: Style.space(10)
    implicitHeight: Style.space(10)

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      // Closed rounded square — the arrow lives inside it, doesn't break
      // the border (the earlier open-box design did, and read as messy).
      // PathRoundedRect doesn't exist in this Qt (confirmed against the
      // real installed qmltypes, not assumed) — four straight edges and
      // four quarter-circle corners instead.
      ShapePath {
        strokeWidth: Style.space(1.6)
        strokeColor: openIcon.strokeColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin

        startX: openIcon.width * (8 / 24); startY: openIcon.height * (4.5 / 24)
        PathLine { x: openIcon.width * (16 / 24); y: openIcon.height * (4.5 / 24) }
        PathArc {
          x: openIcon.width * (19.5 / 24); y: openIcon.height * (8 / 24)
          radiusX: openIcon.width * (3.5 / 24); radiusY: openIcon.height * (3.5 / 24)
          direction: PathArc.Clockwise
        }
        PathLine { x: openIcon.width * (19.5 / 24); y: openIcon.height * (16 / 24) }
        PathArc {
          x: openIcon.width * (16 / 24); y: openIcon.height * (19.5 / 24)
          radiusX: openIcon.width * (3.5 / 24); radiusY: openIcon.height * (3.5 / 24)
          direction: PathArc.Clockwise
        }
        PathLine { x: openIcon.width * (8 / 24); y: openIcon.height * (19.5 / 24) }
        PathArc {
          x: openIcon.width * (4.5 / 24); y: openIcon.height * (16 / 24)
          radiusX: openIcon.width * (3.5 / 24); radiusY: openIcon.height * (3.5 / 24)
          direction: PathArc.Clockwise
        }
        PathLine { x: openIcon.width * (4.5 / 24); y: openIcon.height * (8 / 24) }
        PathArc {
          x: openIcon.width * (8 / 24); y: openIcon.height * (4.5 / 24)
          radiusX: openIcon.width * (3.5 / 24); radiusY: openIcon.height * (3.5 / 24)
          direction: PathArc.Clockwise
        }
      }

      // Arrow shaft, entirely inside the square.
      ShapePath {
        strokeWidth: Style.space(1.7)
        strokeColor: openIcon.strokeColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        startX: openIcon.width * (9.5 / 24); startY: openIcon.height * (14.5 / 24)
        PathLine { x: openIcon.width * (15 / 24); y: openIcon.height * (9 / 24) }
      }

      // Arrowhead — a corner bracket, not a filled triangle, matching
      // the stroke-only style everywhere else in this panel.
      ShapePath {
        strokeWidth: Style.space(1.7)
        strokeColor: openIcon.strokeColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: openIcon.width * (11 / 24); startY: openIcon.height * (8.7 / 24)
        PathLine { x: openIcon.width * (15 / 24); y: openIcon.height * (9 / 24) }
        PathLine { x: openIcon.width * (14.7 / 24); y: openIcon.height * (13 / 24) }
      }
    }
  }

  // ---- destination (queue) row -----------------------------------------

  // One card per environment (production, staging, …), two labeled
  // mini-blocks inside it — DEPLOY (what's actually running, and how it
  // compares to what CI verified) above QUEUE (Solid Queue health)
  // below, split by a thin rule. Two blocks, not one section header
  // repeating both words: the row itself already says which category
  // each fact belongs to, so "Environments" up in queuesSection's own
  // header doesn't have to.
  component DestRow: Item {
    id: destRow
    required property var modelData

    readonly property var queueEntry: destRow.modelData.queue
    readonly property var deployEntry: destRow.modelData.deploy
    readonly property bool queueBad: destRow.queueEntry ? Model.isBad(destRow.queueEntry.state) : false
    readonly property bool queueStalled: destRow.queueEntry ? Model.isStalled(destRow.queueEntry.state) : false
    readonly property string deployFreshness: destRow.deployEntry ? Model.deployFreshnessKind(destRow.deployEntry) : "unknown"
    readonly property bool deployBad: destRow.deployEntry ? Model.isBad(destRow.deployEntry.state) : false
    readonly property bool deployStale: destRow.deployFreshness === "stale"
    // The row as a whole reads as bad/stalled if either half does — one
    // card, one destination, not two independent severities competing
    // for attention.
    readonly property bool bad: destRow.queueBad || destRow.deployBad
    readonly property bool stalled: destRow.queueStalled || destRow.deployStale
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
        : destRow.stalled
          ? Qt.rgba(themeColors.warn.r, themeColors.warn.g, themeColors.warn.b, 0.12)
          : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.05)

      Rectangle {
        // Left accent bar — the same severity cue as the pill, at a glance
        // even when the row is scrolled so its badge text is cut off.
        width: Style.space(3)
        height: parent.height
        radius: Style.cornerRadius
        color: destRow.bad
          ? root.urgent
          : destRow.stalled
            ? themeColors.warn
            : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.3)
      }

      Column {
        id: destContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(9)
        spacing: Style.space(7)

        Text {
          id: destName
          width: parent.width
          text: destRow.modelData.destination
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        // ---- DEPLOY ------------------------------------------------
        Item {
          id: deployBlock
          width: parent.width
          height: Math.max(deployLeft.implicitHeight, deployBadge.height) + Style.space(7)

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.1)
          }

          Row {
            id: deployLeft
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              text: "DEPLOY"
              color: Qt.darker(root.barForeground, 1.6)
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.caption * 0.8)
              font.bold: true
            }

            Text {
              visible: text !== ""
              text: Model.deployShaLabel(destRow.deployEntry)
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Rectangle {
            id: deployBadge
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.cornerRadius
            width: deployBadgeText.implicitWidth + Style.space(10)
            height: deployBadgeText.implicitHeight + Style.space(4)
            color: destRow.deployBad
              ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.2)
              : destRow.deployStale
                ? Qt.rgba(themeColors.warn.r, themeColors.warn.g, themeColors.warn.b, 0.2)
                : destRow.deployFreshness === "fresh"
                  ? Qt.rgba(themeColors.success.r, themeColors.success.g, themeColors.success.b, 0.16)
                  : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.1)

            Text {
              id: deployBadgeText
              anchors.centerIn: parent
              text: Model.deployBadgeLabel(destRow.deployEntry)
              color: destRow.deployBad
                ? root.urgent
                : destRow.deployStale
                  ? themeColors.warn
                  : destRow.deployFreshness === "fresh"
                    ? themeColors.success
                    : Qt.darker(root.barForeground, destRow.deployEntry && destRow.deployEntry.state === "checking" ? 1.6 : 1.15)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: !destRow.deployEntry || destRow.deployEntry.state !== "checking"
              font.italic: destRow.deployEntry !== null && destRow.deployEntry.state === "checking"
            }
          }

          MouseArea {
            id: deployHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            enabled: destRow.deployEntry !== null && destRow.deployEntry.state === "unreachable"
          }

          PanelToolTip {
            visible: deployHover.enabled && deployHover.containsMouse
            text: destRow.deployEntry ? Model.queueErrorDetail(destRow.deployEntry) : ""
          }
        }

        // ---- QUEUE ---------------------------------------------------
        Item {
          width: parent.width
          height: Math.max(queueLeft.implicitHeight, queueBadge.height)

          Row {
            id: queueLeft
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              id: queueEyebrow
              anchors.verticalCenter: parent.verticalCenter
              text: "QUEUE"
              color: Qt.darker(root.barForeground, 1.6)
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.caption * 0.8)
              font.bold: true
            }

            Row {
              id: statsRow
              visible: destRow.stats.length > 0
              anchors.verticalCenter: parent.verticalCenter
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
                    color: statChip.modelData.warn ? themeColors.warn : Qt.darker(root.barForeground, 1.1)
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

          Rectangle {
            id: queueBadge
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.cornerRadius
            width: queueBadgeText.implicitWidth + Style.space(10)
            height: queueBadgeText.implicitHeight + Style.space(4)
            color: destRow.queueBad
              ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.2)
              : destRow.queueStalled
                ? Qt.rgba(themeColors.warn.r, themeColors.warn.g, themeColors.warn.b, 0.2)
                : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.1)

            Text {
              id: queueBadgeText
              anchors.centerIn: parent
              text: Model.destBadgeLabel(destRow.queueEntry)
              // Not bold, italic instead — a provisional status message
              // ("checking…"), not a result, same visual language as the
              // "no CI runs found" / "no Kamal destinations configured"
              // messages elsewhere in this panel.
              color: destRow.queueBad
                ? root.urgent
                : destRow.queueStalled
                  ? themeColors.warn
                  : Qt.darker(root.barForeground, destRow.checking ? 1.6 : 1.15)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: !destRow.checking
              font.italic: destRow.checking
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
    }
  }

  // LoadingSpinner used to be defined inline here — now its own file
  // (LoadingSpinner.qml, same directory), reused from BarWidget.qml too.
}
