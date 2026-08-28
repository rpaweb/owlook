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
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

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
          spacing: Style.space(14)

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
              required property int index
              width: column.width
              spacing: Style.space(10)

              PanelSeparator {
                width: parent.width
                foreground: root.barForeground
                visible: projectBlock.index > 0
              }

              Text {
                width: projectBlock.width
                text: projectBlock.modelData.project
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              // CI: a section of its own, never mixed visually with
              // destinations — a branch ("master") sitting in the same list
              // as destination names ("staging", "production") could read
              // as if it were one too.
              Column {
                width: projectBlock.width
                spacing: Style.space(4)
                visible: projectBlock.modelData.ci.length > 0

                PanelSectionHeader {
                  text: "CI"
                  foreground: root.barForeground
                }

                Repeater {
                  model: projectBlock.modelData.ci

                  Item {
                    id: ciRow
                    required property var modelData
                    width: projectBlock.width
                    implicitHeight: Math.max(ciIcon.implicitHeight, ciText.implicitHeight)

                    Text {
                      id: ciIcon
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      text: Model.ciIcon(ciRow.modelData.state)
                      color: Model.isBad(ciRow.modelData.state) ? root.urgent : root.barForeground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }

                    Text {
                      id: ciText
                      anchors.left: ciIcon.right
                      anchors.leftMargin: Style.space(8)
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: ciRow.modelData.branch + "  —  " + Model.ciSummary(ciRow.modelData)
                        + "  ·  " + Model.relativeTime(ciRow.modelData.observed_at, root.nowMs)
                      color: Model.isBad(ciRow.modelData.state) ? root.urgent : Qt.darker(root.barForeground, 1.15)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
              }

              // Deploys + queues: one block per destination. deploy is
              // omitted entirely (not "no data yet") — nothing produces
              // that kind in v1, and a permanent placeholder line for a
              // feature that doesn't exist is just noise.
              Column {
                width: projectBlock.width
                spacing: Style.space(4)
                visible: projectBlock.modelData.destinations.length > 0

                PanelSectionHeader {
                  text: "DEPLOYS & QUEUES"
                  foreground: root.barForeground
                }

                Repeater {
                  model: projectBlock.modelData.destinations

                  Column {
                    id: destBlock
                    required property var modelData
                    width: projectBlock.width
                    spacing: Style.space(2)

                    Text {
                      width: destBlock.width
                      text: destBlock.modelData.destination
                      color: root.barForeground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    StatusLine {
                      width: destBlock.width
                      visible: destBlock.modelData.deploy !== null
                      foreground: root.barForeground
                      urgent: root.urgent
                      bad: destBlock.modelData.deploy ? Model.isBad(destBlock.modelData.deploy.state) : false
                      text: destBlock.modelData.deploy
                        ? (Model.stateLabel(destBlock.modelData.deploy.state) + "  ·  "
                            + Model.relativeTime(destBlock.modelData.deploy.observed_at, root.nowMs))
                        : ""
                    }

                    StatusLine {
                      id: queueLine
                      width: destBlock.width
                      visible: destBlock.modelData.queue !== null
                      foreground: root.barForeground
                      urgent: root.urgent
                      bad: destBlock.modelData.queue ? Model.isBad(destBlock.modelData.queue.state) : false
                      text: destBlock.modelData.queue
                        ? (Model.queueShortText(destBlock.modelData.queue) + "  ·  "
                            + Model.relativeTime(destBlock.modelData.queue.observed_at, root.nowMs))
                        : ""

                      MouseArea {
                        id: queueHover
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                        enabled: destBlock.modelData.queue && destBlock.modelData.queue.state === "unreachable"
                      }

                      PanelToolTip {
                        visible: queueHover.enabled && queueHover.containsMouse
                        text: destBlock.modelData.queue ? Model.queueErrorDetail(destBlock.modelData.queue) : ""
                      }
                    }
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
    property alias text: lineText.text

    implicitHeight: lineText.implicitHeight

    Text {
      id: lineText
      width: statusLine.width
      textFormat: Text.PlainText
      color: statusLine.bad ? statusLine.urgent : Qt.darker(statusLine.foreground, 1.15)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
