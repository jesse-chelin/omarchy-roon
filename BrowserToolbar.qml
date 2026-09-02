import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// Everything above the two panes: where you are, how much of it there is,
// the view toggle, and the browser's two text boxes.
//
// Both boxes live here for one reason — they compete for keyboard focus, and
// that competition is where every focus bug came from. Keeping them in one
// component with one FocusArbiter means the arbitration is reviewable in
// about forty lines instead of being spread across a thousand.
//
// The two boxes do different jobs and are built to look it: search queries the
// core and replaces the level; filter narrows the rows already on screen and
// never touches the network. They are never interchangeable, so they never
// share a slot.
Item {
  id: root

  // -- appearance ------------------------------------------------------
  property color foreground: Color.foreground
  property string fontFamily: Style.font.menuFamily
  property int navWidth: Style.space(190)
  property int gap: Style.spacing.md

  // -- what to display -------------------------------------------------
  property string levelTitle: ""
  property string countText: ""
  property string trail: ""
  property bool gridMode: false
  property int rowCount: 0

  // Roon pages long levels, and the filter only ever sees what has arrived.
  // Saying "these 100 rows" beside a gutter reading "788 items" looks like a
  // bug; saying which 100 explains it.
  property int levelTotal: 0

  // A level that states its own title, artist and length in a header does not
  // need the gutter repeating two of them, and "11 items" contradicting
  // "10 tracks" — the gutter counts Roon's leading action, the header does
  // not — is worse than saying nothing.
  property bool detailMode: false

  // A filter is for finding a row among many. Below this it is a full-width
  // text box, the largest control on screen, offering to narrow six things
  // you can already see — which is how the plugin came to show three ways to
  // search at once on its shortest level.
  readonly property int filterThreshold: 12
  readonly property bool filterUseful: rowCount >= filterThreshold

  // `/` still summons it on a short level — the rule is about what the level
  // volunteers, not about what the user is allowed to ask for.
  property bool filterForced: false

  // -- search ----------------------------------------------------------
  // Owned by the browser: it holds the Roon item_key a row-prompt needs, so
  // it decides when a search is open and what the prompt says.
  property bool searching: false
  property string searchPrompt: "Search Roon"

  // Where focus belongs when neither box wants it — the browser's key catcher.
  property Item focusFallback: null

  // -- filter ----------------------------------------------------------
  property string filterText: ""

  // True while either box has the keyboard. The browser gates its key
  // handling on this, so a keystroke can never be both text and navigation.
  readonly property bool editing: filterField.activeFocus || searchField.activeFocus

  signal viewToggleRequested()
  signal searchSubmitted(string text)
  signal searchCancelled()
  signal filterChanged(string text)
  signal stepRequested(int dy)
  signal activateRequested()

  implicitHeight: layout.implicitHeight

  // -- focus -------------------------------------------------------------

  FocusArbiter {
    id: arbiter
    defaultTarget: root.focusFallback
  }

  function focusSearch(prefill) {
    searchField.text = prefill || ""
    searchField.selectAll()
    arbiter.claim(searchField)
  }

  function focusFilter() {
    root.filterForced = true
    arbiter.claim(filterField)
  }

  function releaseFocus() {
    arbiter.release()
  }

  function clearSearchText() {
    searchField.text = ""
  }

  function setFilter(text) {
    filterField.text = text || ""
    if (filterField.text === "") root.filterForced = false
    if (root.filterText !== filterField.text) {
      root.filterText = filterField.text
      root.filterChanged(root.filterText)
    }
  }

  // -- layout ------------------------------------------------------------

  Row {
    id: layout
    width: parent.width
    spacing: root.gap

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: root.navWidth
      spacing: Style.space(2)

      Text {
        width: parent.width
        visible: !root.detailMode
        text: root.levelTitle
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: !root.detailMode
        text: root.countText
        color: Qt.darker(root.foreground, 1.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - root.navWidth - root.gap
      spacing: Style.space(3)

      Item {
        width: parent.width
        height: trailText.implicitHeight

        Text {
          id: trailText
          anchors.left: parent.left
          width: parent.width - viewHint.implicitWidth - root.gap
          text: root.trail
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideLeft
        }

        Text {
          id: viewHint
          anchors.right: parent.right
          text: (root.gridMode ? "grid" : "list") + " · v"
          color: Qt.darker(root.foreground, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.viewToggleRequested()
          }
        }
      }

      // Search: its own framed row, so it can never be mistaken for the
      // filter sitting underneath it.
      BorderSurface {
        width: parent.width
        visible: root.searching
        height: root.searching ? searchRow.implicitHeight + Style.space(8) : 0
        radius: Style.spacing.labelGap
        color: Style.selectedFillFor(root.foreground, Color.accent)
        borderSpec: Border.controlSpec("focus", root.foreground, Color.accent)

        Row {
          id: searchRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: root.gap
          anchors.rightMargin: root.gap
          spacing: root.gap

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Model.GLYPH.magnify + "  " + root.searchPrompt
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          TextField {
            id: searchField
            width: parent.width - Style.space(130)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "artist, album or track — Enter to search"

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.searchCancelled()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.searchSubmitted(searchField.text)
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                arbiter.release()
                root.stepRequested(1)
                event.accepted = true
              }
            }
          }
        }
      }

      TextField {
        id: filterField
        width: parent.width
        // Kept in the tree when it is holding text or the keyboard, so
        // crossing the threshold mid-filter cannot yank the box out from
        // under the cursor.
        visible: root.filterUseful || root.filterText !== "" || root.filterForced
        height: visible ? implicitHeight : 0
        enabled: !root.searching
        opacity: root.searching ? 0.35 : 1.0
        // Counts the rows it acts on, so it reads as "narrow what is here"
        // rather than "search the library".
        placeholderText: {
          if (root.levelTotal > root.rowCount)
            return "Filter the " + root.rowCount + " rows loaded so far…   (/ to focus)"
          return root.rowCount === 1
            ? "Filter 1 row…   (/ to focus)"
            : "Filter these " + root.rowCount + " rows…   (/ to focus)"
        }
        text: root.filterText

        onTextChanged: {
          if (root.filterText !== text) {
            root.filterText = text
            root.filterChanged(text)
          }
        }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.setFilter("")
            root.filterForced = false
            arbiter.release()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            arbiter.release()
            root.activateRequested()
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            arbiter.release()
            root.stepRequested(event.key === Qt.Key_Down ? 1 : -1)
            event.accepted = true
          }
        }
      }
    }
  }
}
