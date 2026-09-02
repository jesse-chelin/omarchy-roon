import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// The category rail. Roon's own top-level list, with the plugin's synthetic
// "Recently played" entry pinned above it.
//
// As with ContentPane, `browser` is a deliberate back-pointer: this renders
// the browser's state rather than owning any.
ListView {
  id: root

  required property var browser
  property var roots: []

  clip: true
  model: roots.length
  currentIndex: browser.navIndex
  boundsBehavior: Flickable.StopAtBounds

  delegate: Rectangle {
    id: navRow
    required property int index

    readonly property var modelData: root.roots[index] || ({})

    readonly property var b: root.browser
    readonly property bool selected: modelData.title === b.selectedRootKey
    readonly property bool current: b.cursorActive && b.focusPane === "nav"
      && index === b.navIndex

    width: root.width
    height: b.navRowHeight
    radius: Style.spacing.labelGap
    color: current ? b.selectedBackground
      : (selected ? Style.selectedFillFor(b.foreground, Color.accent) : "transparent")

    Row {
      anchors.fill: parent
      anchors.leftMargin: navRow.b.inset
      anchors.rightMargin: navRow.b.gap
      spacing: navRow.b.gap

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
        text: navRow.modelData.synthetic
          ? (navRow.modelData.mode === "queue" ? Model.GLYPH.queue : Model.GLYPH.history)
          : Model.rootGlyph(navRow.modelData.title)
        color: navRow.current ? navRow.b.selectedText
          : (navRow.selected ? Color.accent : Qt.darker(navRow.b.foreground, 1.3))
        font.family: navRow.b.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(18) - navRow.b.gap
        text: navRow.modelData.title
        color: navRow.current ? navRow.b.selectedText : navRow.b.foreground
        font.family: navRow.b.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: navRow.selected
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: navMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: function(mouse) {
        navRow.b.selectNavFromPointer(navRow.index, navRow, mouse)
      }
      onClicked: {
        navRow.b.selectRoot(navRow.index)
        navRow.b.focusContent()
      }
    }
  }
}
