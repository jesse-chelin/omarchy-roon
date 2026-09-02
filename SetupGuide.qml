import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// Onboarding surface, shown wherever the plugin would otherwise be an empty
// box: in the bar panel and in the browser.
//
// Roon will not talk to an extension until a human approves it in the Roon
// app, and nothing about a blank widget communicates that. This spells out
// the three steps, names the core once discovery has found one, and keeps a
// live "waiting" line so it is clear the plugin is still trying rather than
// stuck.
Item {
  id: root

  property var status: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real contentWidth: Style.space(320)
  property bool reduceMotion: false

  readonly property var guide: Model.setupSteps(status)
  readonly property bool active: guide !== null
  readonly property color toneColor: {
    if (!guide) return Color.accent
    if (guide.tone === "error") return Color.urgent
    return Color.accent
  }

  visible: active
  implicitWidth: contentWidth
  implicitHeight: active ? column.implicitHeight : 0

  Column {
    id: column
    width: root.contentWidth
    spacing: Style.spacing.xl

    Row {
      spacing: Style.spacing.lg
      width: parent.width

      Text {
        anchors.top: parent.top
        text: Model.GLYPH.music
        color: root.toneColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
      }

      Column {
        anchors.top: parent.top
        width: parent.width - Style.font.display - Style.spacing.lg
        spacing: Style.spacing.xs

        Text {
          width: parent.width
          text: root.guide ? root.guide.heading : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: root.guide ? root.guide.blurb : ""
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          visible: text !== ""
        }
      }
    }

    // Numbered because the order matters — the extension does not appear in
    // Roon's list until the bridge is running and asking to be let in.
    Column {
      width: parent.width
      spacing: Style.spacing.md
      visible: root.guide && root.guide.steps.length > 0

      Repeater {
        model: root.guide ? root.guide.steps : []

        Row {
          required property var modelData
          required property int index

          width: column.width
          spacing: Style.spacing.lg

          Text {
            anchors.top: parent.top
            width: Style.space(18)
            horizontalAlignment: Text.AlignRight
            text: (index + 1) + "."
            color: root.toneColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width - Style.space(18) - Style.spacing.lg
            text: modelData
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.spacing.md
      visible: root.guide && root.guide.waiting !== ""

      // A slow pulse rather than a spinner: this can legitimately sit here
      // for minutes while the user walks to another room to open Roon.
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(7)
        height: width
        radius: width / 2
        color: root.toneColor

        SequentialAnimation on opacity {
          running: !root.reduceMotion && root.visible && root.guide && root.guide.waiting !== ""
          loops: Animation.Infinite
          NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.guide ? root.guide.waiting : ""
        color: Qt.darker(root.foreground, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      width: parent.width
      text: root.status && root.status.core ? "Core: " + root.status.core
        : (root.status && root.status.host ? "Core: " + root.status.host : "")
      color: Qt.darker(root.foreground, 1.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      visible: text !== ""
    }
  }
}
