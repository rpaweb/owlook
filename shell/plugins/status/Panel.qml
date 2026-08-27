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
    var bad = Model.badCount(entries)
    return bad > 0 ? bad + " project(s) need attention" : entries.length + " project(s) passing"
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
            meta: root.entries.length + " project(s)"
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
            model: root.entries

            Column {
              id: row
              required property var modelData
              width: column.width
              spacing: Style.space(2)

              readonly property bool bad: Model.isBad(modelData.state)

              Text {
                width: row.width
                text: modelData.project + " · " + Model.rowLocation(modelData)
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: row.width
                text: Model.stateLabel(modelData.state) + " · "
                  + Model.relativeTime(modelData.observed_at, root.nowMs) + " · " + modelData.source
                color: row.bad ? root.urgent : Qt.darker(root.barForeground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }
}
