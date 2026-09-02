import QtQuick
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// A-Z down the edge of a long list.
//
// The albums level opens on "8 Miles High", "10,000 Days" and "1492: Conquest
// of Paradise" — correctly sorted, and no way at all to reach T. The filter is
// not the answer: it narrows rows, it does not travel. Roon returns the level
// already ordered and the bridge sends where each initial letter starts, so
// this lands exactly where the list actually goes rather than guessing from
// an even distribution the alphabet does not have.
//
// Letters the level has no rows for are drawn anyway and dimmed: a rail that
// changed shape per level would be unlearnable, and the gaps are information.
Item {
  id: root

  required property var browser
  readonly property var b: browser

  // A–Z with "#" leading, for the numerals and symbols Roon sorts first.
  readonly property var alphabet: "#ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("")
  readonly property var marks: b.letters

  readonly property int rowHeight: Math.max(Style.space(9),
    Math.floor(height / alphabet.length))

  implicitWidth: Style.space(14)

  function indexFor(letter) {
    for (var i = 0; i < marks.length; i++)
      if (marks[i].letter === letter) return marks[i].index
    return -1
  }

  function has(letter) {
    return indexFor(letter) >= 0
  }

  // Falls forward to the next letter that exists, so pressing a letter with no
  // rows of its own still moves somewhere sensible instead of doing nothing.
  function jump(letter) {
    var start = root.alphabet.indexOf(letter)
    if (start < 0) return false
    for (var i = start; i < root.alphabet.length; i++) {
      var index = indexFor(root.alphabet[i])
      if (index >= 0) {
        root.b.jumpTo(index)
        return true
      }
    }
    return false
  }

  Column {
    id: strip
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
    spacing: 0

    Repeater {
      model: root.alphabet.length

      Item {
        id: mark
        required property int index

        readonly property string letter: root.alphabet[index]
        readonly property bool present: root.has(letter)
        readonly property bool active: railMouse.containsMouse
          && railMouse.letterUnderPointer === letter

        width: root.implicitWidth
        height: root.rowHeight

        Text {
          anchors.centerIn: parent
          text: mark.letter
          color: mark.active ? Color.accent
            : (mark.present ? Qt.darker(root.b.foreground, 1.45)
                            : Qt.darker(root.b.foreground, 2.6))
          font.family: root.b.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: mark.active
        }
      }
    }
  }

  // One area for the whole rail rather than one per letter: dragging down it
  // should scrub through the alphabet the way a phone's index does, and that
  // is a single gesture, not twenty-seven hover targets.
  MouseArea {
    id: railMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    property string letterUnderPointer: ""

    function letterAt(y) {
      var local = y - strip.y
      var index = Math.floor(local / root.rowHeight)
      if (index < 0 || index >= root.alphabet.length) return ""
      return root.alphabet[index]
    }

    onPositionChanged: function(mouse) {
      letterUnderPointer = letterAt(mouse.y)
      if (pressed && letterUnderPointer !== "") root.jump(letterUnderPointer)
    }
    onExited: letterUnderPointer = ""
    onPressed: function(mouse) {
      letterUnderPointer = letterAt(mouse.y)
      if (letterUnderPointer !== "") root.jump(letterUnderPointer)
    }
  }
}
