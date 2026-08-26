import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar entry point. Owns the pill and bar routing; Panel.qml (loaded
// separately, same pattern as akitaonrails/ai-usagebar) owns reading the
// state file and rendering the popup.
BarWidget {
  id: root
  moduleName: "owlook.status"

  readonly property var panelItem: panelLoader.item

  function toggle() {
    if (panelItem) panelItem.toggle()
  }

  function injectPanel() {
    var target = panelItem
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.panelItem ? root.panelItem.barText() : "🦉"
    active: root.panelItem ? root.panelItem.alarming : false
    tooltipText: root.panelItem ? root.panelItem.tooltipText() : "Owlook"
    horizontalMargin: 8

    onPressed: root.toggle()
  }
}
