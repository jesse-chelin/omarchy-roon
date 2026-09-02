import QtQuick
import QtTest
import "../RoonModel.js" as Model

// The `?` reference and the keys the browser actually answers to are two
// lists that can drift apart, and the one that drifts is always the
// documentation. This pins the shape of the reference and the keys it
// promises; Browser.qml's dispatch is checked against it by eye, but at least
// a shortcut cannot silently vanish from the overlay.
TestCase {
  name: "Shortcuts"

  function collect(gridMode) {
    var groups = Model.shortcutGroups(gridMode)
    var keys = []
    for (var g = 0; g < groups.length; g++)
      for (var i = 0; i < groups[g].keys.length; i++)
        keys = keys.concat(groups[g].keys[i].keys)
    return keys
  }

  function test_groups_are_titled_and_populated() {
    var groups = Model.shortcutGroups(false)
    verify(groups.length >= 4)
    for (var g = 0; g < groups.length; g++) {
      verify(groups[g].title.length > 0)
      verify(groups[g].keys.length > 0)
      for (var i = 0; i < groups[g].keys.length; i++) {
        var row = groups[g].keys[i]
        verify(row.keys.length > 0, groups[g].title + " row " + i + " has no key")
        verify(row.text.length > 0, groups[g].title + " row " + i + " has no description")
      }
    }
  }

  // A grid has no meaningful j/k — the cursor moves in two dimensions — so
  // the reference has to say arrows there and j/k in a list.
  function test_movement_keys_follow_the_view() {
    var list = collect(false)
    var grid = collect(true)
    verify(list.indexOf("j") >= 0)
    verify(list.indexOf("→") < 0)
    verify(grid.indexOf("→") >= 0)
    verify(grid.indexOf("j") < 0)
  }

  // Every key the browser dispatches on has to appear somewhere in the
  // reference, or the overlay is lying about what the window does.
  function test_every_dispatched_key_is_documented() {
    var dispatched = ["tab", "g", "enter", "backspace", "esc",
                      "s", "/", "v", "x", "f", "p", "[", "]",
                      ",", ".", "-", "=", "m", "z"]
    var listed = collect(false)
    for (var i = 0; i < dispatched.length; i++)
      verify(listed.indexOf(dispatched[i]) >= 0, dispatched[i] + " is undocumented")
  }

  // Every empty pane used to say "Choose a category", which was a lie in four
  // of the five places it appeared.
  function test_each_empty_pane_says_what_is_empty() {
    var seen = {}
    var modes = ["queue", "history", "favourites", "search", "level", ""]
    for (var i = 0; i < modes.length; i++) {
      var state = Model.emptyState(modes[i], "", "")
      verify(state.title.length > 0, modes[i] + " has no empty state")
      verify(state.glyph.length > 0, modes[i] + " has no glyph")
      verify(seen[state.title] === undefined, modes[i] + " repeats another pane")
      seen[state.title] = true
    }
  }

  // The two a new user meets first, and the two where "it is empty" alone
  // reads as a fault rather than as a beginning.
  function test_the_two_a_new_user_meets_say_what_would_fill_them() {
    verify(Model.emptyState("history", "", "").hint.length > 0)
    verify(Model.emptyState("favourites", "", "").hint.indexOf("f") >= 0)
  }

  function test_a_filter_that_matches_nothing_names_the_filter() {
    verify(Model.emptyState("history", "backrooms", "").title.indexOf("backrooms") >= 0)
  }

  function test_a_search_that_found_nothing_names_the_query() {
    verify(Model.emptyState("search", "", "Talk Talk").title.indexOf("Talk Talk") >= 0)
  }

  function test_no_key_is_claimed_twice() {
    var listed = collect(false)
    for (var i = 0; i < listed.length; i++)
      compare(listed.indexOf(listed[i]), i, listed[i] + " appears twice")
  }
}
