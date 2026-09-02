import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// Onboarding, and every other state where the plugin has nothing to play.
//
// Roon will not talk to an extension until a human approves it in the Roon
// app, and nothing about a blank widget communicates that. This is the first
// thing a new user sees, and for the minutes it takes them to walk to another
// device and press Enable it is the *only* thing they see — so it is built as
// a surface in its own right rather than a paragraph in a void.
//
// The steps are a numbered sequence joined by a rule, because the order is
// load-bearing: the extension does not appear in Roon's list until the bridge
// is running and asking to be let in.
Item {
  id: root

  property var status: null
  property color foreground: Color.foreground
  property color background: Color.background
  property string fontFamily: Style.font.family
  property real contentWidth: Style.space(320)
  property bool reduceMotion: false

  // The browser gives this a card of its own; the panel is already a card, and
  // a second border 8px inside the first reads as a mistake.
  property bool framed: true

  readonly property var guide: Model.setupSteps(status)
  readonly property bool active: guide !== null
  readonly property bool isError: guide && guide.tone === "error"
  readonly property color toneColor: isError ? Color.urgent : Color.accent

  readonly property int markSize: Style.space(22)
  readonly property int markGap: Style.spacing.lg

  visible: active
  implicitWidth: contentWidth
  implicitHeight: active ? card.height : 0

  BorderSurface {
    id: card
    width: root.contentWidth
    height: column.implicitHeight + (root.framed ? Style.space(28) * 2 : 0)
    radius: Style.spacing.labelGap
    color: root.framed ? Util.alpha(root.toneColor, root.isError ? 0.07 : 0.05) : "transparent"
    borderSpec: root.framed ? Border.flat(Util.alpha(root.toneColor, 0.35), 1) : Border.none()

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: root.framed ? Style.space(28) : 0
      anchors.rightMargin: root.framed ? Style.space(28) : 0
      spacing: Style.space(18)

      // -- who is talking, and what they want --------------------------------
      Row {
        width: parent.width
        spacing: Style.spacing.lg

        BorderSurface {
          anchors.top: parent.top
          width: Style.space(46)
          height: Style.space(46)
          radius: Style.spacing.labelGap
          color: Util.alpha(root.toneColor, 0.14)
          borderSpec: Border.flat(Util.alpha(root.toneColor, 0.4), 1)

          Text {
            anchors.centerIn: parent
            text: root.isError ? Model.GLYPH.close : Model.GLYPH.music
            color: root.toneColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }

        Column {
          anchors.top: parent.top
          anchors.topMargin: Style.space(2)
          width: parent.width - Style.space(46) - Style.spacing.lg
          spacing: Style.space(5)

          Text {
            width: parent.width
            text: root.guide ? root.guide.heading : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: root.guide ? root.guide.blurb : ""
            color: Qt.darker(root.foreground, 1.45)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            lineHeight: 1.3
            visible: text !== ""
          }
        }
      }

      // -- what to do, in order ----------------------------------------------
      Column {
        id: steps
        width: parent.width
        spacing: 0
        visible: root.guide && root.guide.steps.length > 0

        Repeater {
          model: root.guide ? root.guide.steps : []

          Item {
            id: step
            required property var modelData
            required property int index

            readonly property bool last: index === (root.guide ? root.guide.steps.length - 1 : 0)

            width: steps.width
            height: Math.max(root.markSize, label.implicitHeight) + (last ? 0 : Style.space(14))

            // The rule between the marks is what makes this read as a sequence
            // rather than as three unrelated instructions.
            Rectangle {
              visible: !step.last
              x: root.markSize / 2 - width / 2
              y: root.markSize
              width: Math.max(1, Style.space(1))
              height: step.height - root.markSize
              color: Util.alpha(root.toneColor, 0.3)
            }

            BorderSurface {
              id: mark
              width: root.markSize
              height: root.markSize
              radius: width / 2
              color: Util.alpha(root.toneColor, 0.16)
              borderSpec: Border.flat(Util.alpha(root.toneColor, 0.45), 1)

              Text {
                anchors.centerIn: parent
                text: step.index + 1
                color: root.toneColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Text {
              id: label
              anchors.left: mark.right
              anchors.leftMargin: root.markGap
              anchors.right: parent.right
              y: Math.round((root.markSize - implicitHeight) / 2)
              text: step.modelData
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              lineHeight: 1.25
            }
          }
        }
      }

      PanelSeparator {
        foreground: root.foreground
        visible: root.guide && (root.guide.waiting !== "" || coreLine.text !== "")
      }

      // -- what is happening right now ---------------------------------------
      Item {
        width: parent.width
        height: Math.max(waiting.implicitHeight, coreLine.implicitHeight)

        Row {
          spacing: Style.spacing.md
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
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
              running: !root.reduceMotion && root.visible
                && root.guide && root.guide.waiting !== ""
              loops: Animation.Infinite
              NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
            }
          }

          Text {
            id: waiting
            anchors.verticalCenter: parent.verticalCenter
            text: root.guide ? root.guide.waiting : ""
            color: Qt.darker(root.foreground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          id: coreLine
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.status && root.status.core ? root.status.core
            : (root.status && root.status.host ? root.status.host : "")
          color: Qt.darker(root.foreground, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          visible: text !== ""
        }
      }
    }
  }
}
