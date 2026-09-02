import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// The now-playing panel, lifted out of BarWidget and given a hierarchy.
//
// It had grown to eleven blocks of equal weight — artwork, four metadata
// lines, an output readout, a seek bar, six transport controls, volume,
// up-next, an outputs section, a zone list and a browse button — each one
// individually justified when it was added, none of them ever demoted. The
// result was a wall in which the thing you open the panel for competed with
// the thing you touch once a week.
//
// So: what is playing and how to nudge it stays visible; the room, its
// outputs and the settings share one disclosure below the rule, because
// changing room is occasional and balancing outputs rarer still; and the two
// ways out are a footer, not a full-width button.
//
// `widget` is a back-pointer to the BarWidget — the same deliberate pattern
// NavPane and ContentPane use. This renders the widget's state; it owns none.
Item {
  id: root

  required property var widget

  readonly property var bar: widget ? widget.bar : null
  readonly property var service: widget ? widget.service : null
  readonly property var zone: widget ? widget.zone : null
  readonly property bool hasZone: widget ? widget.hasZone : false
  readonly property bool playing: widget ? widget.playing : false
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int controlSize: widget ? widget.transportSize : Style.space(32)

  readonly property var zones: widget ? widget.zones : []
  readonly property var outputs: widget ? widget.zoneOutputs : []
  readonly property var upcoming: widget ? widget.upcoming : []
  readonly property bool queueIsForZone: widget ? widget.queueIsForZone : false
  readonly property int volumePercent: widget ? widget.volumePercent : -1
  readonly property bool muted: widget ? widget.muted : false
  readonly property string outputFormat: widget ? widget.outputFormat : ""
  readonly property bool ready: service !== null && service.ready

  // Only one of these owns the disclosure slot at a time.
  property bool roomsOpen: false
  property bool settingsOpen: false

  onSettingsOpenChanged: if (settingsOpen) roomsOpen = false
  onRoomsOpenChanged: if (roomsOpen) settingsOpen = false

  // The panel reopens at rest. Leaving settings expanded from last time
  // would greet the next glance with preferences instead of the music.
  function reset() {
    roomsOpen = false
    settingsOpen = false
  }

  implicitHeight: column.implicitHeight

  // The shell owns shell.json, and will write a widget setting back into it
  // for us. That is the whole reason a settings surface is possible here: the
  // manifest schema is documentation, not a rendered UI, so without this
  // every preference was a hand-edited file.
  function setSetting(key, value) {
    var registry = bar && bar.shell ? bar.shell.pluginRegistry : null
    if (!registry || !widget) return
    registry.setBarWidget(widget.moduleName, key, value, {})
  }

  function openBrowser() {
    widget.close()
    bar.run("omarchy-shell roon-browser open")
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(10)

    // -- a failure, until it is acknowledged -------------------------------
    //
    // Bridge errors used to arrive as a line in the setup guide and leave
    // again on the next status message, which meant a crash that recovered
    // badly was invisible by the time anyone looked.
    BorderSurface {
      id: errorStrip
      width: parent.width
      visible: root.service && root.service.lastError !== ""
      height: errorRow.implicitHeight + Style.space(12)
      radius: Style.spacing.labelGap
      color: Util.alpha(Color.urgent, 0.14)
      borderSpec: Border.flat(Color.urgent, 1)

      Row {
        id: errorRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: errorStrip.borderLeft + Style.space(10)
        anchors.rightMargin: errorStrip.borderRight + Style.space(4)
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - root.controlSize - parent.spacing
          text: root.service ? root.service.lastError : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          width: root.controlSize
          height: root.controlSize
          iconSize: Style.font.bodySmall
          iconText: Model.GLYPH.close
          foreground: root.fg
          tooltipText: "Dismiss"
          onClicked: root.service.dismissError()
        }
      }
    }

    // Setup guidance stands in for the transport until the core is
    // reachable — the same component the browser uses, so the instructions
    // are identical wherever the user meets them first.
    SetupGuide {
      width: parent.width
      status: root.service ? root.service.status : null
      foreground: root.fg
      fontFamily: root.fontFamily
      reduceMotion: root.widget ? root.widget.reduceMotionSetting : false
      contentWidth: parent.width
      // The popup is already a card; a second border inside it reads as a
      // mistake rather than as emphasis.
      framed: false
    }

    // -- what is playing ---------------------------------------------------
    Row {
      width: parent.width
      spacing: Style.space(12)
      visible: root.hasZone

      BorderSurface {
        width: Style.space(96)
        height: Style.space(96)
        radius: Style.spacing.labelGap
        color: Style.normalFillFor(root.fg, Color.accent)
        borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

        Image {
          anchors.fill: parent
          anchors.margins: Style.space(2)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          sourceSize.width: Style.space(96) * 2
          source: root.zone && root.zone.art ? root.zone.art : ""
          visible: source !== "" && status === Image.Ready
        }

        Text {
          anchors.centerIn: parent
          visible: !root.zone || !root.zone.art
          text: Model.GLYPH.music
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
        }
      }

      Column {
        spacing: Style.space(4)
        width: parent.width - Style.space(108)

        Text {
          text: root.zone && root.zone.title ? root.zone.title : "Nothing playing"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }

        // Artist and album used to be 1.3 and 1.6 grey at 11 and 10px — close
        // enough that the block read as a paragraph instead of a hierarchy.
        // Artist is what anyone scans for, so it gets the contrast.
        Text {
          text: root.zone ? root.zone.artist : ""
          color: Qt.darker(root.fg, 1.15)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
          visible: text !== ""
        }

        Text {
          text: root.zone && root.zone.album ? root.zone.album : ""
          color: Qt.darker(root.fg, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
          visible: text !== ""
        }

        // The room used to be a fourth metadata line here, which gave "where"
        // the same standing as "what". It now leads the disclosure below,
        // next to the controls that change it.

        // What the speaker says it is decoding. Roon carries no format at
        // all, so this comes from the endpoint itself and is labelled "out"
        // rather than presented as the source file's format — for a device
        // Roon transcodes to, those are not the same thing.
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.outputFormat !== ""

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "OUT"
            color: Qt.darker(root.fg, 2.0)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          // Muted, not accented. This was the only coloured line in the
          // block, so the eye landed on the bit depth before the artist —
          // accent should mark state (playing, the active room, progress),
          // not a technical readout that is interesting exactly once.
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(30)
            text: root.outputFormat
            color: Qt.darker(root.fg, 1.9)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    // -- seek --------------------------------------------------------------
    //
    // Track and timecodes are stacked rather than layered: they used to be
    // anchored to the top and bottom of one 16px box, which is less than the
    // two of them need, so the digits sat on the rail.
    Column {
      width: parent.width
      spacing: Style.space(5)
      visible: root.zone && root.zone.length > 0

      Item {
        width: parent.width
        // Taller than the rail so the click target is comfortable without
        // making the rail itself heavy.
        height: Style.space(12)

        Rectangle {
          id: track
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: Style.space(4)
          radius: height / 2
          color: Style.normalFillFor(root.fg, Color.accent)

          Rectangle {
            width: track.width * Model.progressFraction(root.zone)
            height: parent.height
            radius: parent.radius
            color: Color.accent
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: root.zone && root.zone.is_seek_allowed
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: function(mouse) {
            if (!root.zone || !root.zone.length) return
            root.service.seek(root.zone.length * Model.clamp(mouse.x / width, 0, 1), "")
          }
        }
      }

      Item {
        width: parent.width
        height: elapsed.implicitHeight

        Text {
          id: elapsed
          anchors.left: parent.left
          text: Model.duration(root.zone ? root.zone.seek_position : 0)
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.right: parent.right
          text: Model.duration(root.zone ? root.zone.length : 0)
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // -- transport ---------------------------------------------------------
    // Every control gets the same square box, so the hover fill is the same
    // shape wherever the pointer lands. Emphasis on play/pause comes from the
    // accent colour instead of from a bigger button, which is what made the
    // highlights different sizes.
    // Left-aligned with everything else. Centred, it was the only element on
    // the panel with its own axis, and read as imported from another design.
    Row {
      spacing: Style.space(4)
      visible: root.hasZone

      Button {
        width: root.controlSize
        height: root.controlSize
        iconSize: Style.font.icon
        iconText: Model.shuffleGlyph(root.zone && root.zone.shuffle)
        foreground: root.zone && root.zone.shuffle ? Color.accent : root.fg
        tooltipText: root.zone && root.zone.shuffle ? "Shuffle on" : "Shuffle off"
        onClicked: root.service.toggleShuffle("")
      }

      Button {
        width: root.controlSize
        height: root.controlSize
        iconSize: Style.font.icon
        iconText: Model.GLYPH.previous
        foreground: root.fg
        tooltipText: "Previous"
        enabled: root.zone && root.zone.is_previous_allowed
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.service.previous("")
      }

      Button {
        width: root.controlSize
        height: root.controlSize
        iconSize: Style.font.icon
        iconText: Model.playPauseGlyph(root.playing)
        foreground: Color.accent
        tooltipText: root.playing ? "Pause" : "Play"
        enabled: root.zone && (root.zone.is_play_allowed || root.zone.is_pause_allowed)
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.service.playPause("")
      }

      Button {
        width: root.controlSize
        height: root.controlSize
        iconSize: Style.font.icon
        iconText: Model.GLYPH.next
        foreground: root.fg
        tooltipText: "Next"
        enabled: root.zone && root.zone.is_next_allowed
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.service.next("")
      }

      Button {
        width: root.controlSize
        height: root.controlSize
        iconSize: Style.font.icon
        iconText: Model.GLYPH.radio
        foreground: root.zone && root.zone.auto_radio ? Color.accent : root.fg
        tooltipText: root.zone && root.zone.auto_radio
          ? "Roon Radio on — keeps playing when the queue ends"
          : "Roon Radio off — playback stops when the queue ends"
        onClicked: root.service.toggleAutoRadio("")
      }

      Button {
        width: root.controlSize
        height: root.controlSize
        iconSize: Style.font.icon
        iconText: Model.loopGlyph(root.zone ? root.zone.loop : "disabled")
        foreground: root.zone && root.zone.loop !== "disabled" ? Color.accent : root.fg
        tooltipText: root.zone && root.zone.loop === "loop" ? "Repeat all"
          : (root.zone && root.zone.loop === "loop_one" ? "Repeat one" : "Repeat off")
        onClicked: root.service.cycleLoop("")
      }
    }

    // -- volume ------------------------------------------------------------
    Row {
      id: volumeRow
      width: parent.width
      spacing: Style.space(8)
      visible: root.volumePercent >= 0

      readonly property int glyphWidth: Style.space(18)
      readonly property int readoutWidth: Style.space(36)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: volumeRow.glyphWidth
        horizontalAlignment: Text.AlignLeft
        text: root.muted ? Model.GLYPH.muted : Model.GLYPH.volume
        color: root.muted ? Qt.darker(root.fg, 1.6) : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.service.toggleMute("")
        }
      }

      PanelSlider {
        width: parent.width - volumeRow.glyphWidth - volumeRow.readoutWidth - volumeRow.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        bar: root.bar
        minimum: 0
        maximum: 100
        step: 1
        integer: true
        value: Math.max(0, root.volumePercent)
        onMoved: function(percent) { root.service.setVolume(percent, "") }
        onReleased: function(percent) { root.service.setVolume(percent, "") }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: volumeRow.readoutWidth
        horizontalAlignment: Text.AlignRight
        text: root.volumePercent + "%"
        color: Qt.darker(root.fg, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // -- what follows ------------------------------------------------------
    Item {
      width: parent.width
      height: upNext.implicitHeight
      visible: root.queueIsForZone && root.upcoming.length > 0

      Text {
        id: upNext
        anchors.left: parent.left
        width: parent.width - queueCount.implicitWidth - Style.space(10)
        text: Model.GLYPH.queue + "  "
          + Model.queueSummary(root.service ? root.service.queue : [],
                               root.zone ? root.zone.title : "")
        color: Qt.darker(root.fg, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        id: queueCount
        anchors.right: parent.right
        anchors.verticalCenter: upNext.verticalCenter
        text: {
          var left = Model.queueRemaining(root.zone ? root.zone.queue_time_remaining : 0)
          return left !== "" ? left : root.upcoming.length + " queued"
        }
        color: Qt.darker(root.fg, 1.8)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openBrowser()
      }
    }

    PanelSeparator {
      foreground: root.fg
      visible: root.zones.length > 0 || root.ready
    }

    // -- where it is playing -----------------------------------------------
    //
    // One line at rest: the room, and how many more there are. Changing room
    // is occasional and trimming outputs rarer, so neither earns permanent
    // space above the rule.
    Item {
      width: parent.width
      height: roomRow.implicitHeight + Style.space(6)
      visible: root.zones.length > 0 && !root.settingsOpen

      Row {
        id: roomRow
        anchors.left: parent.left
        anchors.right: roomChevron.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: Model.GLYPH.speaker
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.hasZone ? Model.zoneLabel(root.zone) : "No room selected"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.outputs.length > 1
            ? Model.GLYPH.outputs + " " + root.outputs.length + " outputs"
            : (root.zones.length > 1 ? "+" + (root.zones.length - 1) + " more" : "")
          color: Qt.darker(root.fg, 1.7)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          visible: text !== ""
        }
      }

      Text {
        id: roomChevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.roomsOpen ? Model.GLYPH.chevronDown : Model.GLYPH.chevron
        color: Qt.darker(root.fg, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.roomsOpen = !root.roomsOpen
      }
    }

    // -- rooms and their outputs, on request --------------------------------
    Column {
      id: roomsSection
      width: parent.width
      spacing: Style.space(4)
      visible: root.roomsOpen && !root.settingsOpen

      // A zone is one or more outputs. Only worth listing when there is more
      // than one to balance — otherwise the volume slider above already said
      // everything there is to say.
      Repeater {
        model: root.outputs.length > 1 ? root.outputs : []

        Row {
          id: outputRow
          required property var modelData

          readonly property var output: modelData
          readonly property int percent: output.volume ? output.volume.percent : -1

          width: roomsSection.width
          spacing: Style.space(6)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(86)
            text: outputRow.output.display_name
            color: Qt.darker(root.fg, 1.2)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          PanelSlider {
            anchors.verticalCenter: parent.verticalCenter
            width: roomsSection.width - Style.space(86) - Style.space(96)
            bar: root.bar
            minimum: 0
            maximum: 100
            step: 1
            integer: true
            enabled: outputRow.percent >= 0
            opacity: enabled ? 1 : 0.3
            value: Math.max(0, outputRow.percent)
            onMoved: function(v) { root.service.setOutputVolume(outputRow.output.output_id, v) }
            onReleased: function(v) { root.service.setOutputVolume(outputRow.output.output_id, v) }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(30)
            horizontalAlignment: Text.AlignRight
            text: outputRow.percent >= 0 ? outputRow.percent + "%" : "—"
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            width: root.controlSize
            height: root.controlSize
            iconSize: Style.font.bodySmall
            iconText: Model.GLYPH.standby
            foreground: root.fg
            visible: outputRow.output.supports_standby
            tooltipText: "Put " + outputRow.output.display_name + " to sleep"
            onClicked: root.service.standby(outputRow.output.output_id)
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            width: root.controlSize
            height: root.controlSize
            iconSize: Style.font.bodySmall
            iconText: Model.GLYPH.linkOff
            foreground: root.fg
            tooltipText: "Remove " + outputRow.output.display_name + " from the group"
            onClicked: root.service.removeOutputFromZone(outputRow.output.output_id)
          }
        }
      }

      Repeater {
        model: root.zones

        BorderSurface {
          id: zoneRow
          required property var modelData

          readonly property var room: modelData
          readonly property bool selected: root.zone && room && root.zone.zone_id === room.zone_id

          width: roomsSection.width
          height: zoneInner.implicitHeight + Style.space(10)
          radius: Style.spacing.labelGap
          color: selected ? Style.selectedFillFor(root.fg, Color.accent) : "transparent"
          borderSpec: selected ? Border.controlSpec("normal", root.fg, Color.accent) : Border.none()

          Row {
            id: zoneInner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: zoneRow.borderLeft + Style.space(8)
            anchors.rightMargin: zoneRow.borderRight + Style.space(8)
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Model.zoneGlyph()
              color: zoneRow.room.state === "playing" ? Color.accent : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              width: Style.space(18)
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(26)
                - (zoneRow.selected ? 0 : Style.space(2) * root.controlSize)
              spacing: Style.space(1)

              Text {
                text: zoneRow.room.display_name
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: zoneRow.selected
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: Model.nowPlayingLabel(zoneRow.room)
                color: Qt.darker(root.fg, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
                visible: text !== ""
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.service.selectZone(zoneRow.room.zone_id)
          }

          // Two things you can do to a room that is not the one you are
          // listening to: move the music there, or add it to what is already
          // playing. Both are one press.
          Row {
            anchors.right: parent.right
            anchors.rightMargin: zoneRow.borderRight + Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            visible: !zoneRow.selected

            Button {
              width: root.controlSize
              height: root.controlSize
              iconSize: Style.font.bodySmall
              iconText: Model.GLYPH.transfer
              foreground: root.fg
              tooltipText: "Move playback to " + zoneRow.room.display_name
              onClicked: root.service.transfer(root.zone ? root.zone.zone_id : "",
                                               zoneRow.room.zone_id)
            }

            Button {
              width: root.controlSize
              height: root.controlSize
              iconSize: Style.font.bodySmall
              iconText: Model.GLYPH.link
              foreground: root.fg
              enabled: root.widget.canGroupWith(zoneRow.room)
              opacity: enabled ? 1 : 0.35
              tooltipText: enabled
                ? "Play " + zoneRow.room.display_name + " in sync with " + Model.zoneLabel(root.zone)
                : zoneRow.room.display_name + " cannot group with this zone"
              onClicked: root.service.addOutputToZone(
                Model.outputIds(zoneRow.room)[0], root.zone ? root.zone.zone_id : "")
            }
          }
        }
      }
    }

    // -- settings ----------------------------------------------------------
    //
    // Omarchy renders nothing from a widget's schema, so until now every
    // preference here meant hand-editing shell.json. Only the settings with a
    // consequence you would notice are exposed; the rest stay in the file.
    Column {
      width: parent.width
      spacing: Style.space(2)
      visible: root.settingsOpen

      // Settings take the disclosure slot the room row usually holds, so the
      // panel needs to say which of the two you are looking at — and the six
      // rows split cleanly into what the plugin does and how it looks.
      PanelSectionHeader {
        text: "Playback"
        foreground: root.fg
        fontFamily: root.fontFamily
        bottomPadding: Style.space(4)
      }

      Toggle {
        width: parent.width
        label: "Ask speakers for the format"
        description: "Roon reports no format, so the endpoint is asked over the LAN."
        checked: root.widget ? root.widget.outputFormatSetting : true
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("showOutputFormat", !checked)
      }

      Toggle {
        width: parent.width
        label: "Find the core by scanning the network"
        description: "Only when the broadcast search fails, which ufw usually blocks."
        checked: root.widget ? root.widget.discoverySweepSetting : true
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("discoverySweep", !checked)
      }

      Toggle {
        width: parent.width
        label: "Close the browser after playing"
        description: "Picking Play now dismisses the library."
        checked: root.widget ? root.widget.closeAfterActionSetting : true
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("closeBrowserAfterAction", !checked)
      }

      Toggle {
        width: parent.width
        label: "Keep a recently-played log and favourites"
        description: "Kept on this machine. Roon exposes neither to an extension."
        checked: root.widget ? root.widget.keepHistorySetting : true
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("keepHistory", !checked)
      }

      Toggle {
        width: parent.width
        label: "Reduce motion"
        description: "Stops the marquee, the pulse and the fades."
        checked: root.widget ? root.widget.reduceMotionSetting : false
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("reduceMotion", !checked)
      }

      Toggle {
        width: parent.width
        label: "Show volume on screen"
        description: "Uses Omarchy's own OSD, the way the audio widget does."
        checked: root.widget ? root.widget.volumeOsdSetting : true
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("volumeOsd", !checked)
      }

      Toggle {
        width: parent.width
        label: "Announce each track"
        description: "An OSD on every track change. Off by default; it is a lot."
        checked: root.widget ? root.widget.trackOsdSetting : false
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("trackOsd", !checked)
      }

      PanelSectionHeader {
        text: "In the bar"
        foreground: root.fg
        fontFamily: root.fontFamily
        topPadding: Style.space(10)
        bottomPadding: Style.space(4)
      }

      Toggle {
        width: parent.width
        label: "Album art in the bar"
        checked: root.widget ? root.widget.artInBar : true
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("showArtInBar", !checked)
      }

      Toggle {
        width: parent.width
        label: "Progress line in the bar"
        checked: root.widget ? root.widget.showProgress : true
        foreground: root.fg
        accent: Color.accent
        fontFamily: root.fontFamily
        titleSize: Style.font.bodySmall
        onClicked: root.setSetting("showProgress", !checked)
      }

      // The one setting that is not a switch, and the one most likely to be
      // needed: discovery finds a core on the same subnet and nothing else,
      // so a VLAN or a Docker bridge means typing the address. It was the
      // last reason to open shell.json by hand.
      Item {
        width: parent.width
        height: coreField.height + Style.space(14)

        Text {
          id: coreLabel
          anchors.left: parent.left
          anchors.verticalCenter: coreField.verticalCenter
          width: Style.space(96)
          text: "Core address"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        TextField {
          id: coreField
          anchors.left: coreLabel.right
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: Style.space(7)
          foreground: root.fg
          accent: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          placeholderText: "Found automatically"
          // Rebound whenever the stored value changes, so an edit abandoned
          // without Enter does not linger as a lie about what is configured.
          text: root.widget ? root.widget.coreSetting : ""
          onAccepted: {
            root.setSetting("core", text.trim())
            focus = false
          }
        }
      }

      Text {
        width: parent.width
        topPadding: Style.space(6)
        text: Model.statusLine(root.service ? root.service.status : null)
        color: Qt.darker(root.fg, 1.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        visible: text !== ""
      }
    }

    PanelSeparator {
      foreground: root.fg
      visible: root.ready
    }

    // -- the two ways out ---------------------------------------------------
    Item {
      width: parent.width
      height: root.controlSize
      visible: root.ready

      Button {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: root.controlSize
        text: "Browse library"
        iconText: Model.GLYPH.folder
        foreground: root.fg
        onClicked: root.openBrowser()
      }

      Button {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: root.controlSize
        height: root.controlSize
        iconSize: Style.font.bodySmall
        iconText: Model.GLYPH.settings
        foreground: root.settingsOpen ? Color.accent : root.fg
        tooltipText: root.settingsOpen ? "Hide settings" : "Settings"
        onClicked: root.settingsOpen = !root.settingsOpen
      }
    }
  }
}
