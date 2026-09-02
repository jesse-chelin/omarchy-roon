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

  // The middle is fixed and centred on the bar rather than wedged between
  // whatever the two sides happen to measure. That inversion is the whole
  // trick: the seek bar cannot move, so the sides no longer have to hold a
  // rigid width to keep it still — which is what was leaving seventy pixels
  // of nothing beside a short room name like "WIIM".
  readonly property int centreWidth: Math.max(Style.space(260),
    Math.min(Style.space(470), Math.round(width * 0.46)))
  readonly property int flankWidth: Math.max(Style.space(120),
    Math.round((width - centreWidth) / 2) - Style.space(14))

  implicitHeight: Math.max(Style.space(48), artSize + Style.space(8))

  // -- what is playing -----------------------------------------------------
  Row {
    id: leftBlock
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.flankWidth
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
      // Elided at rest, scrolling under the pointer — the same treatment the
      // bar item gets, and what lets this block be narrow enough to leave the
      // seek bar room. A permanent marquee spends most of its cycle showing
      // empty space, which is worse than an ellipsis.
      Item {
        id: titleClip
        width: parent.width
        height: title.implicitHeight
        clip: true

        readonly property bool overflows: title.implicitWidth > width
        readonly property bool scrolling: titleHover.hovered && overflows
          && !root.b.reduceMotion

        Text {
          id: title
          // Silent when there is no zone: the setup card above is already
          // saying what is happening, and a second, shorter, less accurate
          // version of it in the corner only contradicts it.
          text: root.b.toast !== "" ? root.b.toast
            : (root.live ? root.zone.title : (root.b.ready ? "Nothing playing" : ""))
          color: root.b.toast !== "" ? Color.accent : Qt.darker(root.b.foreground, 1.15)
          font.family: root.b.fontFamily
          font.pixelSize: Style.font.bodySmall
          width: titleClip.scrolling ? implicitWidth : titleClip.width
          elide: titleClip.scrolling ? Text.ElideNone : Text.ElideRight

          NumberAnimation on x {
            running: titleClip.scrolling
            loops: Animation.Infinite
            duration: Math.max(5000, title.implicitWidth * 22)
            from: 0
            to: -title.implicitWidth
            easing.type: Easing.Linear
          }

          onXChanged: if (!titleClip.scrolling && x !== 0) x = 0
        }

        HoverHandler { id: titleHover }
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
  // Stacked and right-aligned, which is the only arrangement where a room name
  // cannot move anything. Side by side, a name three times longer than "WIIM"
  // either drags the volume across the bar or sits in a fixed lane with fifty
  // pixels of nothing beside it. On its own row it can be as long as it likes:
  // it grows leftward into empty space and stops at the ellipsis.
  Column {
    id: rightBlock
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(3)

    Row {
      id: volumeGroup
      anchors.right: parent.right
      spacing: Style.space(7)
      visible: root.volumePercent >= 0

      Text {
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
    Text {
      id: room
      anchors.right: parent.right
      visible: root.live
      width: Math.min(implicitWidth, root.flankWidth)
      horizontalAlignment: Text.AlignRight
      text: Model.GLYPH.speaker + "  " + Model.zoneLabel(root.zone)
      color: Color.accent
      font.family: root.b.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.b.cycleZone()
      }
    }
  }

  // -- what you do to it ---------------------------------------------------
  Column {
    id: centreBlock
    anchors.horizontalCenter: parent.horizontalCenter
    width: root.centreWidth
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
