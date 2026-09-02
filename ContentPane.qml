import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// The right-hand pane: a cover grid or a row list, whichever suits the level,
// plus the scroll indicator and empty state they share.
//
// `browser` is a deliberate back-pointer. This is a renderer over the
// browser's state, not an independent component — the delegates read a dozen
// values (metrics, cursor position, provenance, art presence) and pushing all
// of those through properties would be ceremony without isolation. The parts
// that genuinely needed isolating are focus and the toolbar, which have real
// interfaces.
Item {
  id: root

  required property var browser
  property var items: []
  property bool gridMode: false

  function positionAtBeginning() {
    grid.positionViewAtBeginning()
    list.positionViewAtBeginning()
  }

  // A rail jump puts the row at the top rather than merely on screen: the
  // point of pressing "T" is to arrive at T, not to have T somewhere below
  // the fold.
  function jumpTo(index) {
    if (root.gridMode) grid.positionViewAtIndex(index, GridView.Beginning)
    else list.positionViewAtIndex(index, ListView.Beginning)
  }

  // Called only when the keyboard moved the cursor. The views deliberately do
  // not follow currentIndex themselves — see the gate in Browser.qml.
  function revealCursor() {
    var index = root.browser.selectedIndex
    if (index < 0) return
    if (root.gridMode) grid.positionViewAtIndex(index, GridView.Contain)
    else list.positionViewAtIndex(index, ListView.Contain)
  }

  // -- grid: covers first --------------------------------------------------

  GridView {
    id: grid
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: root.browser.gridUsableWidth
    visible: root.gridMode
    clip: true
    // A count, not the array. Roon pages a long level a hundred rows at a
    // time, and handing the view a freshly-built array each page destroyed and
    // rebuilt every delegate on screen — a visible hitch every hundred albums.
    // With an integer model, a page only ever *appends* delegates, and the
    // rows already drawn keep their images and their place.
    model: root.gridMode ? root.items.length : 0
    currentIndex: root.browser.selectedIndex
    highlightFollowsCurrentItem: false
    // Keep two rows of tiles alive past each edge so a wheel scroll is not
    // also a delegate-construction storm, and hold the view on whole pixels
    // so covers and captions do not shimmer while it moves.
    cacheBuffer: Math.max(0, root.browser.tileHeight * 2)
    pixelAligned: true
    cellWidth: root.browser.tileWidth
    cellHeight: root.browser.tileHeight
    boundsBehavior: Flickable.StopAtBounds

    delegate: Item {
      id: tile
      required property int index

      readonly property var modelData: root.items[index] || ({})
      readonly property var b: root.browser
      readonly property bool current: b.cursorActive
        && b.focusPane === "content" && index === b.selectedIndex

      width: b.tileWidth
      height: b.tileHeight

      // Selection has to survive a wall of album art, so it is carried three
      // ways at once: everything else dims back, the selected tile gets a
      // filled frame around the cover *and* its text, and the title takes the
      // accent. Recolouring the title alone was invisible against the covers.
      BorderSurface {
        anchors.fill: parent
        anchors.margins: tile.b.tileGutter
        radius: Style.spacing.labelGap
        color: tile.current ? tile.b.selectedBackground : "transparent"
        borderSpec: tile.current
          ? Border.controlSpec("hover-cursor", tile.b.foreground, Color.accent)
          : Border.none()

        opacity: tile.current ? 1.0 : 0.6
        Behavior on opacity {
          enabled: !tile.b.reduceMotion
          NumberAnimation { duration: 110 }
        }

        Column {
          anchors.fill: parent
          anchors.margins: tile.b.tilePad
          spacing: Style.space(5)

          Rectangle {
            width: tile.b.tileArt
            height: tile.b.tileArt
            radius: Style.space(2)
            color: Style.normalFillFor(tile.b.foreground, Color.accent)
            clip: true

            Image {
              anchors.fill: parent
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              sourceSize.width: tile.b.tileArt * 2
              source: tile.modelData.art || ""
              visible: source !== "" && status === Image.Ready
            }

            // Corner chip rather than a row glyph: on a cover it has to
            // survive whatever artwork sits behind it.
            Rectangle {
              visible: tile.b.levelMixedSource
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(4)
              width: badge.implicitWidth + Style.space(9)
              height: badge.implicitHeight + Style.space(4)
              radius: Style.space(2)
              color: Qt.rgba(0, 0, 0, 0.62)

              Text {
                id: badge
                anchors.centerIn: parent
                text: tile.modelData.catalog ? Model.GLYPH.cloud : Model.GLYPH.harddisk
                color: tile.modelData.catalog ? "#DDDDDD" : Color.accent
                font.family: tile.b.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              anchors.centerIn: parent
              visible: !tile.modelData.art
              text: Model.itemGlyph(tile.modelData)
              color: Qt.darker(tile.b.foreground, 1.3)
              font.family: tile.b.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          Text {
            width: tile.b.tileArt
            text: tile.modelData.title
            color: tile.current ? Color.accent : tile.b.foreground
            font.family: tile.b.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: tile.current
            elide: Text.ElideRight
          }

          // One fact, and it is the artist. When and where it played needs
          // width this tile does not have, so it waits for the list view.
          Text {
            width: tile.b.tileArt
            text: tile.modelData.subtitle
            color: Qt.darker(tile.b.foreground, 1.5)
            font.family: tile.b.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            visible: text !== ""
          }
        }
      }

      MouseArea {
        id: tileMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // No onEntered. A delegate created under a stationary cursor emits
        // one with an unreliable position — often its own top-left — which
        // reads as pointer movement and moves the cursor after a jump or a
        // page. Real motion always produces onPositionChanged.
        onPositionChanged: function(mouse) {
          tile.b.selectFromPointer(tile.index, tile, mouse)
        }
        onClicked: {
          tile.b.cursorActive = true
          tile.b.focusPane = "content"
          tile.b.selectedIndex = tile.index
          tile.b.activate(tile.index)
        }
      }
    }

    onAtYEndChanged: if (contentHeight > height + 1) root.browser.loadMore(atYEnd)
  }

  // -- list: for tracks, actions, settings ---------------------------------

  ListView {
    id: list
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: parent.width - root.browser.scrollbarWidth
    visible: !root.gridMode
    clip: true
    model: root.gridMode ? 0 : root.items.length
    currentIndex: root.browser.selectedIndex
    highlightFollowsCurrentItem: false
    cacheBuffer: Math.max(0, root.browser.rowHeight * 6)
    pixelAligned: true
    highlightMoveDuration: root.browser.reduceMotion ? 0 : 90
    boundsBehavior: Flickable.StopAtBounds

    delegate: Item {
      id: contentRow
      required property int index

      readonly property var b: root.browser
      readonly property var item: root.items[index] || ({})
      readonly property bool isHeader: item.hint === "header"
      readonly property bool current: b.cursorActive
        && b.focusPane === "content" && index === b.selectedIndex

      width: list.width
      height: isHeader ? Style.space(30) : b.rowHeight

      Rectangle {
        anchors.fill: parent
        anchors.topMargin: Style.space(2)
        anchors.bottomMargin: Style.space(2)
        radius: Style.spacing.labelGap
        color: contentRow.current ? contentRow.b.selectedBackground : "transparent"
        visible: !contentRow.isHeader
      }

      Text {
        visible: contentRow.isHeader
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: contentRow.b.inset
        text: contentRow.item.title
        color: Qt.darker(contentRow.b.foreground, 1.6)
        font.family: contentRow.b.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Row {
        visible: !contentRow.isHeader
        anchors.fill: parent
        anchors.leftMargin: contentRow.b.inset
        anchors.rightMargin: contentRow.b.inset
        spacing: contentRow.b.gap

        BorderSurface {
          anchors.verticalCenter: parent.verticalCenter
          visible: contentRow.b.levelHasArt
          width: contentRow.b.artSize
          height: contentRow.b.artSize
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(contentRow.b.foreground, Color.accent)
          borderSpec: Border.none()

          Image {
            anchors.fill: parent
            anchors.margins: 1
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            sourceSize.width: contentRow.b.artSize * 2
            source: contentRow.item.art || ""
            visible: source !== "" && status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: !contentRow.item.art
            text: Model.itemGlyph(contentRow.item)
            color: contentRow.current ? contentRow.b.selectedText
              : Qt.darker(contentRow.b.foreground, 1.3)
            font.family: contentRow.b.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
            - (contentRow.b.levelHasArt ? contentRow.b.artSize + contentRow.b.gap : 0)
            - (contentRow.b.levelMixedSource ? Style.space(20) : 0)
            - contentRow.b.gap - Style.space(12)
          spacing: Style.space(2)

          Text {
            text: contentRow.item.title
            color: contentRow.current ? contentRow.b.selectedText : contentRow.b.foreground
            font.family: contentRow.b.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: contentRow.item.detail
              ? contentRow.item.subtitle + "  ·  " + contentRow.item.detail
              : contentRow.item.subtitle
            color: contentRow.current ? contentRow.b.selectedText
              : Qt.darker(contentRow.b.foreground, 1.5)
            font.family: contentRow.b.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }

        // Where this row came from, shown only in a list holding both kinds —
        // inferred from Roon's entity markup, since browse items carry no
        // provenance field.
        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: contentRow.b.levelMixedSource && !contentRow.isHeader
          text: contentRow.item.catalog ? Model.GLYPH.cloud : Model.GLYPH.harddisk
          color: contentRow.item.catalog ? Qt.darker(contentRow.b.foreground, 1.6) : Color.accent
          font.family: contentRow.b.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(12)
          horizontalAlignment: Text.AlignRight
          text: contentRow.item.hint === "action" ? Model.GLYPH.play
            : (contentRow.item.hint === "header" ? "" : Model.GLYPH.chevron)
          color: Qt.darker(contentRow.b.foreground, 1.5)
          font.family: contentRow.b.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        enabled: !contentRow.isHeader
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: function(mouse) {
          contentRow.b.selectFromPointer(contentRow.index, contentRow, mouse)
        }
        onClicked: {
          contentRow.b.cursorActive = true
          contentRow.b.focusPane = "content"
          contentRow.b.selectedIndex = contentRow.index
          contentRow.b.activate(contentRow.index)
        }
      }
    }

    onAtYEndChanged: if (contentHeight > height + 1) root.browser.loadMore(atYEnd)
  }

  // Position within a level Roon reports the true size of; a 788-item list
  // otherwise gives no sense of scale at all.
  Rectangle {
    id: scrollbar
    anchors.right: parent.right
    anchors.top: parent.top
    width: Math.max(2, Style.space(3))
    radius: width / 2
    color: Style.selectedFillFor(root.browser.foreground, Color.accent)
    visible: activeView.contentHeight > activeView.height + 1

    readonly property var activeView: root.gridMode ? grid : list
    readonly property real fraction:
      Math.min(1, activeView.height / Math.max(1, activeView.contentHeight))

    height: Math.max(Style.space(24), parent.height * fraction)
    y: (parent.height - height)
      * (activeView.contentY / Math.max(1, activeView.contentHeight - activeView.height))
  }

  // An empty pane is where a product either explains itself or looks broken.
  Column {
    id: nothing
    anchors.centerIn: parent
    width: Math.min(Style.space(340), parent.width - Style.space(40))
    spacing: Style.space(10)
    visible: root.items.length === 0

    readonly property var blank: Model.emptyState(root.browser.emptyMode,
                                                  root.browser.filterText,
                                                  root.browser.lastQuery)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: nothing.blank.glyph
      color: Util.alpha(root.browser.foreground, 0.28)
      font.family: root.browser.fontFamily
      font.pixelSize: Style.space(44)
    }

    Text {
      width: parent.width
      text: nothing.blank.title
      color: Qt.darker(root.browser.foreground, 1.25)
      font.family: root.browser.fontFamily
      font.pixelSize: Style.font.subtitle
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: nothing.blank.hint
      color: Qt.darker(root.browser.foreground, 1.9)
      font.family: root.browser.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      lineHeight: 1.3
    }
  }
}
