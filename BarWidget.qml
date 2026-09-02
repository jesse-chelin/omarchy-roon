import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// Now-playing readout for the bar, plus the popup that holds transport,
// zone switching and volume. The heavy lifting lives in the service; this
// file is presentation and input mapping only.
//
// Left click  — open the panel. This is the discoverable action: a bar item
//               that does something invisible on left click teaches nobody.
// Right click — play/pause the active zone
// Middle click— next track
// Wheel       — volume on the active zone
BarWidget {
  id: root
  moduleName: "io.github.jesse-chelin.roon"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("io.github.jesse-chelin.roon") : null
  readonly property var zones: service ? service.zones : []
  readonly property var zone: service ? service.activeZone : null

  readonly property bool playing: zone !== null && zone.state === "playing"
  readonly property string title: zone ? zone.title : ""
  readonly property string artist: zone ? zone.artist : ""
  readonly property string label: Model.nowPlayingLabel(zone)
  readonly property bool hasZone: zone !== null

  readonly property real maxLabelWidth: setting("maxLabelWidth", 200)
  readonly property bool showWhenIdle: setting("showWhenIdle", false)
  readonly property bool showProgress: setting("showProgress", true)
  readonly property bool artInBar: setting("showArtInBar", true)
  readonly property string coreSetting: setting("core", "")
  readonly property bool closeAfterActionSetting: setting("closeBrowserAfterAction", true)
  readonly property bool outputFormatSetting: setting("showOutputFormat", true)
  readonly property bool reduceMotionSetting: setting("reduceMotion", false)
  readonly property bool keepHistorySetting: setting("keepHistory", true)
  readonly property string outputFormat: service ? service.outputFormat(zone) : ""
  readonly property string outputDevice: service ? service.outputDevice(zone) : ""
  readonly property var zoneOutputs: zone && zone.outputs ? zone.outputs : []
  readonly property var groupable: service ? Model.groupableOutputIds(zone) : []
  readonly property var queueItems: service ? service.queue : []
  readonly property bool queueIsForZone: service && zone
    && service.queueZoneId === zone.zone_id
  readonly property var upcoming: Model.queueUpcoming(queueItems, root.title)

  // The queue is per zone and streamed on demand, so ask whenever the panel
  // opens onto a different room.
  onZoneChanged: if (service && zone && popupOpen) service.refreshQueue("")
  onPopupOpenChanged: {
    if (popupOpen) {
      if (service && zone) service.refreshQueue("")
    } else {
      // The panel reopens showing the music, never last week's settings.
      panel.reset()
    }
  }

  property bool popupOpen: false
  property bool hovered: false

  readonly property bool marqueeing: hovered && !popupOpen && labelText.overflows
    && !reduceMotionSetting
  onMarqueeingChanged: if (!marqueeing) labelText.x = 0

  // Reads through the service's optimistic override, so a drag tracks the
  // pointer instead of waiting on the core to echo each step back.
  readonly property int volumePercent: service && zone ? service.volumePercentFor(zone) : -1
  readonly property bool muted: Model.zoneMuted(zone)

  // The bar host drives panel-bearing widgets through open/close/opened, and
  // its popout coordinator uses closeForPopoutSwitch to hand focus to another
  // bar panel. Implementing all four is what makes
  // `omarchy-shell shell toggle io.github.jesse-chelin.roon` bindable to a key.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  // Roon decides which endpoints can play in sync; asking it beats guessing.
  function canGroupWith(other) {
    if (!other || !zone) return false
    var ids = Model.groupableOutputIds(zone)
    var theirs = Model.outputIds(other)
    for (var i = 0; i < theirs.length; i++) if (ids.indexOf(theirs[i]) !== -1) return true
    return false
  }
  function toggle() { popupOpen = !popupOpen }
  function closeForPopoutSwitch() { popupOpen = false }

  // Spell the bindings out. A bar icon has no affordances of its own, so the
  // tooltip is the only place a user can discover what the buttons do.
  function tooltipText() {
    if (!service || !service.ready) return service ? service.statusLine : "Roon"
    var lines = []
    if (hasError) lines.push(service.lastError, "")
    if (hasZone) {
      lines.push(Model.zoneLabel(zone) + (label ? " — " + label : ""))
      if (outputFormat) lines.push("Output: " + outputFormat
        + (outputDevice ? "  (" + outputDevice + ")" : ""))
      lines.push("")
    }
    lines.push("Click: panel · Right: play/pause")
    lines.push("Middle: next · Scroll: volume")
    return lines.join("\n")
  }

  // The service is shared by every bar instance, so push the configured core
  // exactly once rather than from each monitor's copy of this widget.
  // The overlay gets no shell.json settings of its own, so the widget — which
  // does — is where the plugin's preferences are read and handed to the
  // shared service.
  function pushSettings() {
    if (!service) return
    if (service.coreHost !== coreSetting) service.coreHost = coreSetting
    service.closeBrowserAfterAction = closeAfterActionSetting
    service.showOutputFormat = outputFormatSetting
    service.reduceMotion = reduceMotionSetting
    service.keepHistory = keepHistorySetting
  }

  onServiceChanged: pushSettings()
  onCoreSettingChanged: pushSettings()
  onCloseAfterActionSettingChanged: pushSettings()
  onOutputFormatSettingChanged: pushSettings()
  onReduceMotionSettingChanged: pushSettings()
  onKeepHistorySettingChanged: pushSettings()

  readonly property bool needsSetup: !service || !service.ready

  // A bridge failure that nobody has acknowledged. It used to scroll past
  // in the status line and be gone by the time anyone looked; now it marks
  // the bar item until the panel dismisses it.
  readonly property bool hasError: service !== null && service.lastError !== ""

  // Once the widget is in the bar it stays there. It used to render nothing
  // when every zone was stopped, which removed the only way into the plugin
  // at exactly the moment someone wanted to start something. `showWhenIdle`
  // now decides whether the *label* appears when idle, not whether the plugin
  // is reachable.
  readonly property bool idle: !hasZone || label === ""
  readonly property bool showLabel: needsSetup || !idle || showWhenIdle

  readonly property int transportSize: Math.max(Style.space(32), Style.font.icon + Style.spacing.controlPaddingY * 2)
  visible: true
  implicitWidth: vertical ? barSize : row.implicitWidth + Style.space(14)
  // An idle widget is a glyph, not a gap.
  implicitHeight: vertical ? column.implicitHeight + Style.space(10) : barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)
    visible: !root.vertical

    // The cover, when there is one. Small enough to sit in a bar and still be
    // recognisable — you know your own records at this size.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: root.artInBar && root.zone && root.zone.art ? Style.space(16) : 0
      height: width
      radius: Style.space(2)
      color: "transparent"
      clip: true
      visible: width > 0

      Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: Style.space(16) * 3
        source: root.zone && root.zone.art ? root.zone.art : ""
        visible: source !== "" && status === Image.Ready
      }
    }

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      visible: !(root.artInBar && root.zone && root.zone.art)
      text: Model.barGlyph()
      color: root.needsSetup || root.hasError ? Color.urgent
        : (root.playing ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5))
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color {
        enabled: !root.reduceMotionSetting && (!root.bar || root.bar.foregroundAnimationEnabled)
        ColorAnimation { duration: 160 }
      }
    }

    Item {
      id: scrollClip
      width: Math.min(root.maxLabelWidth, labelText.implicitWidth)
      height: glyph.height
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showLabel

      // Elided at rest, scrolling only under the pointer. A permanent marquee
      // spends most of its cycle showing empty space, so the one thing the
      // bar item exists to tell you — what is playing — was usually absent.
      Text {
        id: labelText
        text: root.needsSetup ? "Roon — setup" : (root.idle ? "Roon" : root.label)
        color: root.bar.barForeground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter

        readonly property bool overflows: implicitWidth > scrollClip.width

        width: root.marqueeing ? implicitWidth : scrollClip.width
        elide: root.marqueeing ? Text.ElideNone : Text.ElideRight

        NumberAnimation on x {
          running: root.marqueeing
          loops: Animation.Infinite
          duration: Math.max(6000, labelText.implicitWidth * 25)
          from: scrollClip.width
          to: -labelText.implicitWidth
          easing.type: Easing.Linear
        }
      }
    }

    // The glyph carries the tint, but album art replaces the glyph — so the
    // error needs a mark of its own that art cannot hide.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.hasError
      width: Style.space(5)
      height: width
      radius: width / 2
      color: Color.urgent
    }
  }

  // A vertical bar has no room for a scrolling label; show the state glyph
  // alone and let the popup carry the detail.
  Column {
    id: column
    anchors.centerIn: parent
    spacing: Style.space(2)
    visible: root.vertical

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: Model.barGlyph()
      color: root.needsSetup || root.hasError ? Color.urgent
        : (root.playing ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5))
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  // A hairline under the label, so how far through a track you are is
  // answerable without opening anything. Bound to the same seek position the
  // panel uses, and drawn only while something is actually playing.
  Rectangle {
    id: barProgress
    visible: root.showProgress && !root.vertical && root.hasZone
      && root.zone.length > 0 && root.label !== ""
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(2)
    anchors.left: row.left
    width: row.width * Model.progressFraction(root.zone)
    height: Math.max(1, Style.space(1))
    radius: height / 2
    color: root.playing ? Color.accent : Qt.darker(root.bar.barForeground, 1.8)
    Behavior on width {
      enabled: !root.reduceMotionSetting
      NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        if (root.service) root.service.next("")
      } else if (mouse.button === Qt.RightButton) {
        if (root.service && root.hasZone) root.service.playPause("")
      } else {
        root.popupOpen = !root.popupOpen
      }
    }

    onWheel: function(wheel) {
      if (!root.service) return
      root.service.stepVolume(wheel.angleDelta.y > 0 ? 3 : -3, "")
    }

    onEntered: {
      root.hovered = true
      if (root.bar) root.bar.showTooltip(root, root.tooltipText())
    }
    onExited: {
      root.hovered = false
      if (root.bar) root.bar.hideTooltip(root)
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(panel.implicitHeight)

    PlaybackPanel {
      id: panel
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      widget: root
    }
  }
}
