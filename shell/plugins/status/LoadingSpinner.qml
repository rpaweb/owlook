import QtQuick
import QtQuick.Shapes
import qs.Commons

// A rotating open ring (Shape + PathAngleArc, the same technique the
// shell's own speed-test dials use) — not a word. "checking…" as text
// read as a broken/empty state, not a busy one; a spinner is the
// unambiguous "still working on it" signal for what's otherwise a
// completely empty section (or, at bar-pill scale, for the status dot
// while nothing's resolved yet).
Item {
  id: spinner

  property color foreground: Color.accent
  property bool running: true
  property real strokeWidth: Style.space(3)

  implicitWidth: Style.space(28)
  implicitHeight: Style.space(28)

  Shape {
    id: arc
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    opacity: spinner.running ? 1 : 0

    RotationAnimation on rotation {
      from: 0
      to: 360
      duration: 900
      loops: Animation.Infinite
      running: spinner.running
    }

    ShapePath {
      strokeWidth: spinner.strokeWidth
      strokeColor: spinner.foreground
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: arc.width / 2
        centerY: arc.height / 2
        radiusX: (arc.width - spinner.strokeWidth) / 2
        radiusY: (arc.height - spinner.strokeWidth) / 2
        startAngle: 0
        sweepAngle: 270
      }
    }
  }
}
