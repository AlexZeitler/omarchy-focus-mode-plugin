import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Bar widget: sets how strongly focus mode dims and how gray it turns the
// wallpaper. While the panel is open, the service shows focus mode with the
// slider values, so each change is visible at once. The bar stays meanwhile.
Panel {
  id: root
  moduleName: "alexzeitler.focus-mode"
  ipcTarget: "alexzeitler.focus-mode"

  readonly property real defaultDim: 0.7
  readonly property real defaultGrayscale: 1

  // The service of this plugin. Without it, the panel falls back to IPC.
  readonly property var service: root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
    ? root.bar.shell.serviceFor(root.moduleName) : null

  readonly property real dim: root.service ? root.service.configuredDim : clamp01(root.setting("dim", defaultDim), defaultDim)
  readonly property real grayscale: root.service ? root.service.configuredGrayscale : clamp01(root.setting("grayscale", defaultGrayscale), defaultGrayscale)

  // What the sliders show. PanelSlider resets its knob to `value` on release,
  // while the saved setting only comes back once the shell has written
  // shell.json and the service has read it again. Bound to the setting
  // directly, the knob jumped back to the old value and then to the new one.
  // These follow every move at once, and the saved setting once it arrives.
  property real dimValue: dim
  property real grayscaleValue: grayscale
  onDimChanged: dimValue = dim
  onGrayscaleChanged: grayscaleValue = grayscale

  // As an escape rather than the glyph itself: a literal private-use character
  // does not survive every editor and pipe it passes through.
  readonly property string barIcon: ""

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(fg, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  function clamp01(value, fallback) {
    if (value === true) return 1
    if (value === false) return 0
    var n = Number(value)
    if (isNaN(n)) return fallback
    return Math.max(0, Math.min(1, n))
  }

  function percent(value) {
    return Math.round(value * 100) + "%"
  }

  function preview() {
    var d = root.dimValue
    var g = root.grayscaleValue
    if (root.service) root.service.setPreview(d, g)
    else Quickshell.execDetached(["omarchy-shell", "focus-mode", "preview", String(d), String(g)])
  }

  function endPreview() {
    if (root.service) root.service.endPreview()
    else Quickshell.execDetached(["omarchy-shell", "focus-mode", "endPreview"])
  }

  // The shell replaces the whole entry, so the settings it already holds,
  // such as the key, go along.
  function persist() {
    var next = {}
    for (var k in root.settings) if (k !== "id") next[k] = root.settings[k]
    next.dim = Math.round(root.dimValue * 100) / 100
    next.grayscale = Math.round(root.grayscaleValue * 100) / 100
    root.dimValue = next.dim
    root.grayscaleValue = next.grayscale
    root.settings = next
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  onOpenedChanged: {
    if (opened) root.preview()
    else root.endPreview()
  }

  Component.onDestruction: if (root.opened) root.endPreview()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    tooltipText: "Focus mode"
    onPressed: function(which) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.close()

      ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: "Focus mode"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          Layout.fillWidth: true
        }

        RowLayout {
          Layout.fillWidth: true
          Text {
            textFormat: Text.PlainText
            text: "Dim"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            Layout.fillWidth: true
          }
          Text {
            textFormat: Text.PlainText
            text: root.percent(dimSlider.liveValue)
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSlider {
          id: dimSlider
          bar: root.bar
          Layout.fillWidth: true
          minimum: 0
          maximum: 1
          step: 0.05
          value: root.dimValue
          onMoved: function(v) { root.dimValue = v; root.preview() }
          onReleased: function(v) { root.persist() }
        }

        RowLayout {
          Layout.fillWidth: true
          Text {
            textFormat: Text.PlainText
            text: "Grayscale"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            Layout.fillWidth: true
          }
          Text {
            textFormat: Text.PlainText
            text: root.percent(graySlider.liveValue)
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSlider {
          id: graySlider
          bar: root.bar
          Layout.fillWidth: true
          minimum: 0
          maximum: 1
          step: 0.05
          value: root.grayscaleValue
          onMoved: function(v) { root.grayscaleValue = v; root.preview() }
          onReleased: function(v) { root.persist() }
        }
      }
    }
  }
}
