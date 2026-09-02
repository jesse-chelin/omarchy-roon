import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// The browser's player bar.
//
// It started as three transport buttons and a track title, which closed the
// worst gap — browsing was a dead end for playback — and then stopped there.
// Everything else still meant leaving the window: the volume, the position in
// the track, whether shuffle was on. A library browser that cannot turn the
// music down is not finished.
//
// Three blocks, because that is what the width is for: what is playing on the
// left, what you do to it in the middle, how loud and where on the right. The
// height is fixed whether or not there is a zone, a toast or artwork — the
// card above it must never move.
Item {
  id: root

  required property var browser
  readonly property var b: browser
  readonly property var service: b.service
  readonly property var zone: b.zone

  readonly property bool live: b.ready && zone !== null
  readonly property int controlSize: b.footerControlSize
  readonly property int artSize: Style.space(40)
  readonly property int volumePercent: service && zone ? service.volumePercentFor(zone) : -1
  readonly property bool muted: Model.zoneMuted(zone)

  // Bounded rather than proportional at the extremes: below ~700px the middle
  // block runs out of room for a seek bar before the sides run out of text.
  readonly property int sideWidth: Math.max(Style.space(180),
    Math.min(Style.space(300), Math.round(width * 0.30)))

  implicitHeight: Math.max(Style.space(48), artSize + Style.space(8))

  // -- what is playing -----------------------------------------------------
  Row {
    id: leftBlock
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.sideWidth
    spacing: Style.space(9)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: root.live && root.zone.art ? root.artSize : 0
      height: width
      radius: Style.space(3)
      color: "transparent"
      clip: true
      visible: width > 0

      Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: root.artSize * 3
        source: root.live && root.zone.art ? root.zone.art : ""
        visible: source !== "" && status === Image.Ready
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - (root.live && root.zone.art ? root.artSize + parent.spacing : 0)
      spacing: Style.space(1)

      // A toast lands here rather than displacing a control. It is about the
      // music, it belongs with the music, and nothing moves while it shows.
      Text {
        width: parent.width
        // Silent when there is no zone: the setup card above is already
        // saying what is happening, and a second, shorter, less accurate
        // version of it in the corner only contradicts it.
        text: root.b.toast !== "" ? root.b.toast
          : (root.live ? root.zone.title : (root.b.ready ? "Nothing playing" : ""))
        color: root.b.toast !== "" ? Color.accent : Qt.darker(root.b.foreground, 1.15)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.b.toast === "" && text !== ""
        text: root.live ? root.zone.artist : ""
        color: Qt.darker(root.b.foreground, 1.8)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // -- how loud, and where -------------------------------------------------
  //
  // Fixed width, every part of it. Room names vary — "WIIM" and "Media Room -
  // Sonos" differ by ninety pixels — and this block anchors the right edge of
  // the seek bar, so a name that sized itself made the seek bar jump every
  // time you changed rooms. The room sits last and elides into its lane.
  Row {
    id: rightBlock
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(16)
    width: volumeGroup.width + spacing + roomLane.width

    Row {
      id: volumeGroup
      spacing: Style.space(7)
      width: root.volumePercent >= 0
        ? glyph.width + spacing + slider.width + spacing + readout.width : 0
      visible: root.volumePercent >= 0

      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        text: root.muted ? Model.GLYPH.muted : Model.GLYPH.volume
        color: root.muted ? Color.urgent : Qt.darker(root.b.foreground, 1.3)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.bodySmall

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.service.toggleMute("")
        }
      }

      PanelSlider {
        id: slider
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(96)
        trackColor: Style.selectedFillFor(root.b.foreground, Color.accent)
        fillColor: root.b.foreground
        knobColor: root.b.foreground
        tickColor: root.b.background
        minimum: 0
        maximum: 100
        step: 1
        integer: true
        opacity: root.muted ? 0.45 : 1
        value: Math.max(0, root.volumePercent)
        onMoved: function(percent) { root.service.setVolume(percent, "") }
        onReleased: function(percent) { root.service.setVolume(percent, "") }
      }

      Text {
        id: readout
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        horizontalAlignment: Text.AlignRight
        text: root.volumePercent + "%"
        color: Qt.darker(root.b.foreground, 1.7)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // The active room: the most consequential piece of state in a multi-room
    // product, so it gets one unmistakable place per surface, and that place
    // is the one you press to change it.
    Item {
      id: roomLane
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(104)
      height: room.implicitHeight

      Text {
        id: room
        anchors.fill: parent
        visible: root.live
        text: Model.GLYPH.speaker + "  " + Model.zoneLabel(root.zone)
        color: Color.accent
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.b.cycleZone()
        }
      }
    }
  }

  // -- what you do to it ---------------------------------------------------
  Column {
    id: centreBlock
    anchors.left: leftBlock.right
    anchors.right: rightBlock.left
    anchors.leftMargin: root.b.gap
    anchors.rightMargin: root.b.gap
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)
    visible: root.live

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(2)

      Button {
        width: root.controlSize; height: root.controlSize
        iconSize: Style.font.bodySmall
        iconText: Model.shuffleGlyph(root.zone && root.zone.shuffle)
        foreground: root.zone && root.zone.shuffle ? Color.accent : Qt.darker(root.b.foreground, 1.5)
        tooltipText: root.zone && root.zone.shuffle ? "Shuffle on" : "Shuffle off"
        onClicked: root.service.toggleShuffle("")
      }

      Button {
        width: root.controlSize; height: root.controlSize
        iconSize: Style.font.bodySmall
        iconText: Model.GLYPH.previous
        foreground: root.b.foreground
        enabled: root.zone && root.zone.is_previous_allowed
        opacity: enabled ? 1 : 0.35
        tooltipText: "Previous  ·  ["
        onClicked: root.service.previous("")
      }

      Button {
        width: root.controlSize; height: root.controlSize
        iconSize: Style.font.body
        iconText: Model.playPauseGlyph(root.zone && root.zone.state === "playing")
        foreground: Color.accent
        tooltipText: (root.zone && root.zone.state === "playing" ? "Pause" : "Play") + "  ·  p"
        onClicked: root.service.playPause("")
      }

      Button {
        width: root.controlSize; height: root.controlSize
        iconSize: Style.font.bodySmall
        iconText: Model.GLYPH.next
        foreground: root.b.foreground
        enabled: root.zone && root.zone.is_next_allowed
        opacity: enabled ? 1 : 0.35
        tooltipText: "Next  ·  ]"
        onClicked: root.service.next("")
      }

      Button {
        width: root.controlSize; height: root.controlSize
        iconSize: Style.font.bodySmall
        iconText: Model.loopGlyph(root.zone ? root.zone.loop : "disabled")
        foreground: root.zone && root.zone.loop !== "disabled"
          ? Color.accent : Qt.darker(root.b.foreground, 1.5)
        tooltipText: root.zone && root.zone.loop === "loop" ? "Repeat all"
          : (root.zone && root.zone.loop === "loop_one" ? "Repeat one" : "Repeat off")
        onClicked: root.service.cycleLoop("")
      }
    }

    // Position, and a way to change it. A player bar that shows how far
    // through a track you are but will not let you move is a readout, not a
    // control — and this one already had the rail drawn for it in the panel.
    Item {
      width: parent.width
      height: Style.space(12)
      visible: root.zone && root.zone.length > 0

      Text {
        id: elapsed
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(32)
        text: Model.duration(root.zone ? root.zone.seek_position : 0)
        color: Qt.darker(root.b.foreground, 1.8)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: total
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(32)
        horizontalAlignment: Text.AlignRight
        text: Model.duration(root.zone ? root.zone.length : 0)
        color: Qt.darker(root.b.foreground, 1.8)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        anchors.left: elapsed.right
        anchors.right: total.left
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height

        Rectangle {
          id: rail
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: Style.space(3)
          radius: height / 2
          color: Style.normalFillFor(root.b.foreground, Color.accent)

          Rectangle {
            width: rail.width * Model.progressFraction(root.zone)
            height: parent.height
            radius: parent.radius
            color: Color.accent

            Behavior on width {
              enabled: !root.b.reduceMotion
              NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
            }
          }
        }

        // Only under the pointer: a permanent handle on a 3px rail reads as
        // clutter in a bar this size, and the rail is clickable anywhere.
        Rectangle {
          visible: railMouse.containsMouse && railMouse.enabled
          x: rail.width * Model.progressFraction(root.zone) - width / 2
          anchors.verticalCenter: rail.verticalCenter
          width: Style.space(8)
          height: width
          radius: width / 2
          color: Color.accent
        }

        MouseArea {
          id: railMouse
          anchors.fill: parent
          hoverEnabled: true
          enabled: root.zone && root.zone.is_seek_allowed
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: function(mouse) {
            if (!root.zone || !root.zone.length) return
            root.service.seek(root.zone.length * Model.clamp(mouse.x / width, 0, 1), "")
          }
        }
      }
    }
  }

  // Before there is a zone the bar still holds its height, so the card above
  // does not resize the moment the core connects.
  Text {
    anchors.centerIn: parent
    visible: !root.live
    text: root.b.ready ? "" : "esc  close"
    color: Qt.darker(root.b.foreground, 1.8)
    font.family: root.b.fontFamily
    font.pixelSize: Style.font.caption
  }
}
