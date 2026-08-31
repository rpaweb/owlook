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

  // WidgetButton only ever renders a single centered Text label — no icon
  // slot — so it keeps doing every bit of interaction (click, hover,
  // tooltip, bar registration) exactly as before, on the same barText()
  // string it always used (still the right width to reserve). What's new
  // is labelVisible: false, so that text never actually paints; the Row
  // below draws the real pill content on top of it, purely decorative
  // (no MouseArea of its own, so clicks/hover still land on the button
  // beneath it untouched).
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.panelItem ? root.panelItem.barText() : "🦉"
    labelVisible: false
    active: root.panelItem ? root.panelItem.alarming : false
    tooltipText: root.panelItem ? root.panelItem.tooltipText() : "Owlook"
    horizontalMargin: 8

    onPressed: root.toggle()
  }

  Row {
    anchors.centerIn: button
    spacing: Style.space(4)

    OwlIcon {
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: button.fontSize
      implicitHeight: button.fontSize
    }

    Text {
      readonly property string badge: root.panelItem ? root.panelItem.badgeText() : ""
      visible: badge !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: badge
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
    }
  }
}
