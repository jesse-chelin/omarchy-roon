import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// The `?` overlay.
//
// Every shortcut the browser answers to, laid out by what you are trying to
// do rather than by keycap order. It exists because the footer could only
// ever show the first six before eliding, and the ones past the ellipsis were
// exactly the ones nobody had learned yet.
Item {
  id: root

  property color foreground: Color.foreground
  property color background: Color.background
  property string fontFamily: Style.font.family
  property bool gridMode: false
  property bool reduceMotion: false

  signal dismissed()

  readonly property var groups: Model.shortcutGroups(gridMode)
  readonly property int columnGap: Style.space(28)

  // Swallows the click that would otherwise reach the browser behind it.
  MouseArea {
    anchors.fill: parent
    onClicked: root.dismissed()
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.97)
  }

  Column {
    anchors.centerIn: parent
    width: Math.min(Style.space(660), parent.width - Style.space(64))
    spacing: Style.space(18)

    Item {
      width: parent.width
      height: heading.implicitHeight

      Text {
        id: heading
        anchors.left: parent.left
        text: "Keyboard"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: heading.verticalCenter
        text: "? or esc to close"
        color: Qt.darker(root.foreground, 1.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Grid {
      width: parent.width
      columns: 2
      columnSpacing: root.columnGap
      rowSpacing: Style.space(18)

      Repeater {
        model: root.groups

        Column {
          id: group
          required property var modelData

          width: (parent.width - root.columnGap) / 2
          spacing: Style.space(6)

          PanelSectionHeader {
            text: group.modelData.title
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: group.modelData.keys

            Row {
              id: shortcutRow
              required property var modelData

              width: group.width
              spacing: Style.space(8)

              Row {
                id: caps
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Repeater {
                  model: shortcutRow.modelData.keys

                  BorderSurface {
                    id: cap
                    required property string modelData

                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(Style.space(20), capText.implicitWidth + Style.space(10))
                    height: Style.space(20)
                    radius: Style.space(3)
                    color: Style.normalFillFor(root.foreground, Color.accent)
                    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                    Text {
                      id: capText
                      anchors.centerIn: parent
                      text: cap.modelData
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }

              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: group.width - caps.width - parent.spacing
                text: shortcutRow.modelData.text
                color: Qt.darker(root.foreground, 1.25)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }
    }

    Text {
      width: parent.width
      text: "The mouse works everywhere too — click a category, click a cover, "
        + "drag the seek bar or the volume. Everything here is also on the "
        + "player bar along the bottom."
      color: Qt.darker(root.foreground, 1.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  Behavior on opacity {
    enabled: !root.reduceMotion
    NumberAnimation { duration: 110 }
  }
}
