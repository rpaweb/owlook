import QtQuick
import QtQuick.Shapes
import qs.Commons

// Owlook's mark: two ring eyes with solid pupils, a diamond beak, and an
// equilateral brow triangle. Coordinates are fractions of a 0-100 box,
// ported exactly from the approved mockup SVG (viewBox 0 0 100 100) —
// not a fresh guess at the same shape, same technique as VerdictIcon and
// LoadingSpinner elsewhere in this panel (Shape/ShapePath, not a glyph).
//
// Fixed amber tones, not Color.accent: this is a logo, not a themed status
// icon, so it deliberately doesn't reskin with the active Omarchy theme.
Item {
  id: root

  property color ringColor: "#e8ab52"
  property color beakColor: "#c98a2e"

  implicitWidth: Style.space(28)
  implicitHeight: Style.space(28)

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeWidth: root.width * (7 / 100)
      strokeColor: root.ringColor
      fillColor: "transparent"
      PathAngleArc {
        centerX: root.width * (32 / 100)
        centerY: root.height * (42 / 100)
        radiusX: root.width * (15 / 100)
        radiusY: root.height * (15 / 100)
        startAngle: 0
        sweepAngle: 360
      }
    }

    ShapePath {
      strokeWidth: root.width * (7 / 100)
      strokeColor: root.ringColor
      fillColor: "transparent"
      PathAngleArc {
        centerX: root.width * (68 / 100)
        centerY: root.height * (42 / 100)
        radiusX: root.width * (15 / 100)
        radiusY: root.height * (15 / 100)
        startAngle: 0
        sweepAngle: 360
      }
    }

    ShapePath {
      fillColor: root.ringColor
      strokeColor: "transparent"
      PathAngleArc {
        centerX: root.width * (32 / 100)
        centerY: root.height * (42 / 100)
        radiusX: root.width * (6 / 100)
        radiusY: root.height * (6 / 100)
        startAngle: 0
        sweepAngle: 360
      }
    }

    ShapePath {
      fillColor: root.ringColor
      strokeColor: "transparent"
      PathAngleArc {
        centerX: root.width * (68 / 100)
        centerY: root.height * (42 / 100)
        radiusX: root.width * (6 / 100)
        radiusY: root.height * (6 / 100)
        startAngle: 0
        sweepAngle: 360
      }
    }

    ShapePath {
      fillColor: root.beakColor
      strokeColor: "transparent"
      startX: root.width * (50 / 100); startY: root.height * (53 / 100)
      PathLine { x: root.width * (60 / 100); y: root.height * (65 / 100) }
      PathLine { x: root.width * (50 / 100); y: root.height * (81 / 100) }
      PathLine { x: root.width * (40 / 100); y: root.height * (65 / 100) }
    }

    ShapePath {
      fillColor: root.ringColor
      strokeColor: "transparent"
      startX: root.width * (41 / 100); startY: root.height * (19 / 100)
      PathLine { x: root.width * (59 / 100); y: root.height * (19 / 100) }
      PathLine { x: root.width * (50 / 100); y: root.height * (31 / 100) }
    }
  }
}
