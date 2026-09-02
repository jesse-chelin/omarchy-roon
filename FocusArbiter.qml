import QtQuick

// Decides who owns keyboard focus inside the browser overlay.
//
// This exists because the same bug happened three times. Hiding a focused
// TextField makes Qt hand focus to the next item in the scope — often the
// other text field, sometimes nothing — so focus has to be reclaimed *after*
// that reassignment rather than during it. That means Qt.callLater, which
// means two reclaims can be in flight at once, and whichever ran second won.
// The visible symptoms were a filter box that ignored typing and an overlay
// that stopped responding to keys entirely.
//
// The rule is simply: the last stated intention wins, evaluated when the
// event loop settles rather than when the call was made. Both directions go
// through here so there is exactly one place to reason about, and one place
// to test — see tests/tst_focusarbiter.qml.
QtObject {
  id: root

  // Where focus belongs when nothing has claimed it: normally the key
  // catcher, so the list responds to j/k.
  property Item defaultTarget: null

  // True while a field has been deliberately claimed. Callers use this to
  // decide whether keystrokes belong to a text box or to the cursor.
  readonly property bool claimed: _claimed

  property bool _claimed: false
  property Item _pending: null

  signal settled(Item target)

  // Give focus to a specific field, beating any pending release.
  function claim(field) {
    if (!field)
      return
    _claimed = true
    _pending = field
    Qt.callLater(_apply)
  }

  // Hand focus back to defaultTarget, beating any pending claim.
  function release() {
    _claimed = false
    _pending = null
    Qt.callLater(_apply)
  }

  // Reads the *current* intention, not the one in force when it was
  // scheduled. Several of these can be queued in one turn; they all reach the
  // same conclusion, so the extra runs are harmless.
  function _apply() {
    var target = _claimed ? _pending : defaultTarget
    if (!target)
      return
    target.forceActiveFocus()
    root.settled(target)
  }
}
