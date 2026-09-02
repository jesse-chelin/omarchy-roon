import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// An album or an artist, given the screen it deserves.
//
// Roon hands every level the same payload, and this plugin rendered all of
// them the same way: a row list. For an album that meant the cover thrown
// away, "Play Album" as row one, and twelve tracks each repeating the
// identical five-name credit — on the screen where someone decides whether to
// press play. The level's own cover is what marks it out (only an album or an
// artist has one), so this pane takes over whenever there is one.
//
// The cursor is untouched: index 0 is still Roon's leading action and index
// i+1 is still row i, so every key the browser already answers to keeps
// working over a completely different layout.
Item {
  id: root

  required property var browser
  property var items: []

  readonly property var body: Model.detailBody(items)
  readonly property var rows: body.rows
  readonly property bool asGrid: Model.detailIsGrid(rows)
  readonly property var b: browser

  readonly property string title: b.browse && b.browse.title ? b.browse.title : ""
  readonly property string subtitle: b.browse && b.browse.subtitle ? b.browse.subtitle : ""
  readonly property string art: b.browse && b.browse.art ? b.browse.art : ""
  readonly property bool actionCurrent: b.cursorActive
    && b.focusPane === "content" && b.selectedIndex === 0

  readonly property int coverSize: Style.space(148)

  function positionAtBeginning() {
    trackList.positionViewAtBeginning()
    albumGrid.positionViewAtBeginning()
  }

  // Index 0 is the header's play action, so row i sits at cursor i + 1.
  function revealCursor() {
    var index = root.b.selectedIndex - 1
    if (index < 0) return
    if (root.asGrid) albumGrid.positionViewAtIndex(index, GridView.Contain)
    else trackList.positionViewAtIndex(index, ListView.Contain)
  }

  // -- the record itself ---------------------------------------------------
  Item {
    id: header
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: root.coverSize + Style.space(16)

    BorderSurface {
      id: cover
      anchors.left: parent.left
      anchors.top: parent.top
      width: root.coverSize
      height: root.coverSize
      radius: Style.spacing.labelGap
      color: Style.normalFillFor(root.b.foreground, Color.accent)
      borderSpec: Border.controlSpec("normal", root.b.foreground, Color.accent)

      Image {
        anchors.fill: parent
        anchors.margins: Style.space(2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: root.coverSize * 2
        source: root.art
        visible: source !== "" && status === Image.Ready
      }

      Text {
        anchors.centerIn: parent
        visible: root.art === ""
        text: root.asGrid ? Model.GLYPH.artist : Model.GLYPH.album
        color: Qt.darker(root.b.foreground, 1.3)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.displayLarge
      }
    }

    Column {
      anchors.left: cover.right
      anchors.right: parent.right
      anchors.leftMargin: Style.space(20)
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: root.title
        color: root.b.foreground
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.display
        font.bold: true
        elide: Text.ElideRight
        maximumLineCount: 2
        wrapMode: Text.Wrap
      }

      Text {
        width: parent.width
        text: root.subtitle
        color: Qt.darker(root.b.foreground, 1.25)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.subtitle
        elide: Text.ElideRight
        visible: text !== ""
      }

      // What Roon knows about a record from out here is its length in rows.
      // It carries no year, no label and no format, so this says the one true
      // thing rather than inventing a discography line.
      Text {
        width: parent.width
        text: Model.detailCount(root.subtitle, root.rows, root.asGrid)
        color: Qt.darker(root.b.foreground, 1.75)
        font.family: root.b.fontFamily
        font.pixelSize: Style.font.caption
        visible: text !== ""
      }

      Item { width: 1; height: Style.space(6) }

      Row {
        spacing: Style.space(8)

        // One press plays it. The action Roon offers here is a menu — Play
        // Now, Add Next, Queue, Start Radio — and making the common case walk
        // through it was the plugin charging two keystrokes for the verb the
        // whole screen exists to deliver.
        Button {
          height: Style.space(34)
          text: root.asGrid ? "Play artist" : "Play album"
          iconText: Model.GLYPH.play
          foreground: root.b.foreground
          hasCursor: root.actionCurrent
          enabled: root.body.action !== null
          opacity: enabled ? 1 : 0.4
          tooltipText: "Play now  ·  enter for the other options"
          onClicked: root.b.playDefault()
        }

        Button {
          height: Style.space(34)
          width: Style.space(34)
          iconSize: Style.font.body
          iconText: Model.GLYPH.more
          foreground: root.b.foreground
          enabled: root.body.action !== null
          opacity: enabled ? 1 : 0.4
          tooltipText: "Play next, queue, start radio…"
          onClicked: root.b.activate(0)
        }

        // The plugin's own list, not Roon's — the extension API has no
        // favourites at all, so this is labelled as ours wherever it shows.
        Button {
          height: Style.space(34)
          width: Style.space(34)
          iconSize: Style.font.body
          iconText: root.b.isFavourite ? Model.GLYPH.heart : Model.GLYPH.heartOff
          foreground: root.b.isFavourite ? Color.accent : root.b.foreground
          tooltipText: root.b.isFavourite
            ? "In your favourites  ·  f"
            : "Add to favourites  ·  f  (this plugin's own list)"
          onClicked: root.b.toggleFavourite()
        }
      }
    }
  }

  PanelSeparator {
    id: rule
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: header.bottom
    anchors.topMargin: Style.space(4)
    foreground: root.b.foreground
  }

  // -- the tracks, or the artist's records ---------------------------------
  ListView {
    id: trackList
    anchors.left: parent.left
    anchors.top: rule.bottom
    anchors.topMargin: Style.space(6)
    anchors.bottom: parent.bottom
    width: parent.width - root.b.scrollbarWidth
    visible: !root.asGrid
    clip: true
    model: root.asGrid ? 0 : root.rows.length
    currentIndex: root.b.selectedIndex - 1
    highlightFollowsCurrentItem: false
    cacheBuffer: Style.space(38) * 6
    pixelAligned: true
    highlightMoveDuration: root.b.reduceMotion ? 0 : 90
    boundsBehavior: Flickable.StopAtBounds

    delegate: Item {
      id: trackRow
      required property int index

      readonly property var modelData: root.rows[index] || ({})

      readonly property bool current: root.b.cursorActive
        && root.b.focusPane === "content" && root.b.selectedIndex === index + 1

      width: trackList.width
      height: Style.space(38)

      Rectangle {
        anchors.fill: parent
        anchors.topMargin: Style.space(1)
        anchors.bottomMargin: Style.space(1)
        radius: Style.spacing.labelGap
        color: trackRow.current ? root.b.selectedBackground : "transparent"
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: root.b.inset
        anchors.rightMargin: root.b.inset
        spacing: Style.space(14)

        // Roon bakes the index into the title ("4. The Pot"). A number column
        // reads as a track list; a numbered sentence reads as a list of files.
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(24)
          horizontalAlignment: Text.AlignRight
          text: trackRow.modelData.number > 0 ? trackRow.modelData.number : ""
          color: trackRow.current ? root.b.selectedText : Qt.darker(root.b.foreground, 2.0)
          font.family: root.b.fontFamily
          font.pixelSize: Style.font.caption
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(38) - parent.spacing
          spacing: Style.space(1)

          Text {
            width: parent.width
            text: trackRow.modelData.title
            color: trackRow.current ? root.b.selectedText : root.b.foreground
            font.family: root.b.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          // Only survives when it says something the row above did not.
          Text {
            width: parent.width
            text: trackRow.modelData.subtitle
            color: trackRow.current ? root.b.selectedText : Qt.darker(root.b.foreground, 1.6)
            font.family: root.b.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            visible: text !== ""
          }
        }
      }

      MouseArea {
        id: trackMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: function(mouse) {
          root.b.selectFromPointer(trackRow.index + 1, trackRow, mouse)
        }
        onClicked: {
          root.b.cursorActive = true
          root.b.focusPane = "content"
          root.b.selectedIndex = trackRow.index + 1
          root.b.activate(trackRow.index + 1)
        }
      }
    }
  }

  GridView {
    id: albumGrid
    anchors.left: parent.left
    anchors.top: rule.bottom
    anchors.topMargin: Style.space(6)
    anchors.bottom: parent.bottom
    width: root.b.gridUsableWidth
    visible: root.asGrid
    clip: true
    model: root.asGrid ? root.rows.length : 0
    currentIndex: root.b.selectedIndex - 1
    highlightFollowsCurrentItem: false
    cacheBuffer: Math.max(0, root.b.tileHeight * 2)
    pixelAligned: true
    cellWidth: root.b.tileWidth
    cellHeight: root.b.tileHeight
    boundsBehavior: Flickable.StopAtBounds

    delegate: Item {
      id: releaseTile
      required property int index

      readonly property var modelData: root.rows[index] || ({})

      readonly property bool current: root.b.cursorActive
        && root.b.focusPane === "content" && root.b.selectedIndex === index + 1

      width: root.b.tileWidth
      height: root.b.tileHeight

      BorderSurface {
        anchors.fill: parent
        anchors.margins: root.b.tileGutter
        radius: Style.spacing.labelGap
        color: releaseTile.current ? root.b.selectedBackground : "transparent"
        borderSpec: releaseTile.current
          ? Border.controlSpec("hover-cursor", root.b.foreground, Color.accent)
          : Border.none()
        opacity: releaseTile.current ? 1.0 : 0.6

        Behavior on opacity {
          enabled: !root.b.reduceMotion
          NumberAnimation { duration: 110 }
        }

        Column {
          anchors.fill: parent
          anchors.margins: root.b.tilePad
          spacing: Style.space(5)

          Rectangle {
            width: root.b.tileArt
            height: root.b.tileArt
            radius: Style.spacing.labelGap
            color: Style.normalFillFor(root.b.foreground, Color.accent)
            clip: true

            Image {
              anchors.fill: parent
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              sourceSize.width: root.b.tileArt * 2
              source: releaseTile.modelData.art
              visible: source !== "" && status === Image.Ready
            }
          }

          Text {
            width: root.b.tileArt
            text: releaseTile.modelData.title
            color: releaseTile.current ? Color.accent : root.b.foreground
            font.family: root.b.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      MouseArea {
        id: releaseMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: function(mouse) {
          root.b.selectFromPointer(releaseTile.index + 1, releaseTile, mouse)
        }
        onClicked: {
          root.b.cursorActive = true
          root.b.focusPane = "content"
          root.b.selectedIndex = releaseTile.index + 1
          root.b.activate(releaseTile.index + 1)
        }
      }
    }
  }
}
