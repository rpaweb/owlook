import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Reads $XDG_RUNTIME_DIR/owlook.json (written by the owlook collector) via
// FileView with watchChanges: true — no polling, no process spawned by this
// widget. See Owlook::StateWriter for the write side.
Panel {
  id: root
  moduleName: "owlook.status"
  manageIpc: false

  property var anchorItem: null

  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string statePath: runtimeDir + "/owlook.json"

  property var entries: []
  property double nowMs: Date.now()

  readonly property bool alarming: Model.anyBad(entries)

  function barText() { return Model.barText(entries) }

  function tooltipText() {
    if (entries.length === 0) return "Owlook — waiting for the collector"
    // entries counts rows (ci + queue + deploy), not distinct projects — a
    // single project with two failing destinations is 2 rows, not 2
    // projects, so "check(s)" rather than "project(s)".
    var bad = Model.badCount(entries)
    return bad > 0 ? bad + " check(s) need attention" : entries.length + " check(s) passing"
  }

  function applyState(raw) {
    root.entries = Model.parseEntries(raw)
  }

  onOpenedChanged: if (opened) nowMs = Date.now()

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
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
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Owlook"
            meta: Model.groupByProject(root.entries).length + " project(s)"
            foreground: root.barForeground
            fontFamily: Style.font.family

            iconComponent: Component {
              Text {
                text: "🦉"
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }

          Text {
            visible: root.entries.length === 0
            width: parent.width
            text: "No data yet — is the collector running?"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: Model.groupByProject(root.entries)

            Column {
              id: projectBlock
              required property var modelData
              width: column.width
              spacing: Style.space(6)

              Text {
                width: projectBlock.width
                text: projectBlock.modelData.project
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }

              // CI: one row per branch observed (usually just one — whatever
              // branch the local checkout was on when the collector polled).
              Repeater {
                model: projectBlock.modelData.ci

                StatusLine {
                  width: projectBlock.width
                  foreground: root.barForeground
                  urgent: root.urgent
                  bad: Model.isBad(modelData.state)
                  label: "branch " + (modelData.branch || "?")
                  detail: Model.stateLabel(modelData.state) + " · "
                    + Model.relativeTime(modelData.observed_at, root.nowMs) + " · " + modelData.source
                }
              }

              // Deploy + queue: one block per destination, joined here for
              // display even though they're separate rows in the state file
              // (see Model.groupByProject).
              Repeater {
                model: projectBlock.modelData.destinations

                Column {
                  id: destBlock
                  required property var modelData
                  width: projectBlock.width
                  spacing: Style.space(2)

                  StatusLine {
                    width: destBlock.width
                    foreground: root.barForeground
                    urgent: root.urgent
                    bad: destBlock.modelData.deploy ? Model.isBad(destBlock.modelData.deploy.state) : false
                    label: destBlock.modelData.destination
                    detail: destBlock.modelData.deploy
                      ? (Model.stateLabel(destBlock.modelData.deploy.state) + " · "
                          + Model.relativeTime(destBlock.modelData.deploy.observed_at, root.nowMs))
                      : "no deploy data yet"
                  }

                  StatusLine {
                    width: destBlock.width
                    visible: destBlock.modelData.queue !== null
                    foreground: root.barForeground
                    urgent: root.urgent
                    bad: destBlock.modelData.queue ? Model.isBad(destBlock.modelData.queue.state) : false
                    label: "  queue"
                    detail: destBlock.modelData.queue
                      ? (Model.queueDetailText(destBlock.modelData.queue) + " · "
                          + Model.relativeTime(destBlock.modelData.queue.observed_at, root.nowMs))
                      : ""
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component StatusLine: Item {
    id: statusLine
    property color foreground: Color.foreground
    property color urgent: Color.urgent
    property bool bad: false
    property string label: ""
    property string detail: ""

    implicitHeight: lineText.implicitHeight

    Text {
      id: lineText
      width: statusLine.width
      text: statusLine.label + (statusLine.detail !== "" ? "  ·  " + statusLine.detail : "")
      textFormat: Text.PlainText
      color: statusLine.bad ? statusLine.urgent : Qt.darker(statusLine.foreground, 1.25)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
