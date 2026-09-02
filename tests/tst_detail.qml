import QtQuick
import QtTest
import "../RoonModel.js" as Model

// The album screen's model. Roon hands the same payload shape to every level,
// so what makes a detail screen is entirely a matter of reading it correctly;
// these are the readings the layout depends on.
TestCase {
  name: "DetailLevel"

  readonly property var albumItems: [
    { title: "Play Album", subtitle: "", hint: "action_list", art: "", item_key: "a0" },
    { title: "1. Vicarious", subtitle: "Tool, Justin Chancellor, Adam Jones", hint: "action_list", art: "", item_key: "k1" },
    { title: "2. Jambi", subtitle: "Tool, Justin Chancellor, Adam Jones", hint: "action_list", art: "", item_key: "k2" },
    { title: "3. Wings for Marie, Pt. 1", subtitle: "Tool, Justin Chancellor, Adam Jones", hint: "action_list", art: "", item_key: "k3" },
    { title: "4. The Pot", subtitle: "Tool, Justin Chancellor, Adam Jones", hint: "action_list", art: "", item_key: "k5" }
  ]

  readonly property var artistItems: [
    { title: "Play Artist", subtitle: "", hint: "action_list", art: "", item_key: "k4" },
    { title: "Laughing Stock", subtitle: "1991", hint: "list", art: "x1", item_key: "b1" },
    { title: "Spirit of Eden", subtitle: "1988", hint: "list", art: "x2", item_key: "b2" }
  ]

  function test_only_a_level_with_a_cover_is_a_detail_screen() {
    verify(Model.isDetailLevel({ art: "http://core/img/abc", title: "10,000 Days" }))
    verify(!Model.isDetailLevel({ art: "", title: "Albums" }))
    verify(!Model.isDetailLevel(null))
  }

  function test_track_numbers_come_out_of_the_title() {
    compare(Model.trackNumber("1. Vicarious"), 1)
    compare(Model.trackNumber("10,000 Days (Wings, Pt. 2)"), 0)
    compare(Model.trackNumber("4. 10,000 Days (Wings, Pt. 2)"), 4)
    compare(Model.stripTrackNumber("4. 10,000 Days (Wings, Pt. 2)"), "10,000 Days (Wings, Pt. 2)")
    // A title that merely opens with digits is not a numbered track.
    compare(Model.trackNumber("99 Cents"), 0)
    compare(Model.stripTrackNumber("99 Cents"), "99 Cents")
  }

  function test_the_credit_repeated_on_every_row_is_dropped() {
    var body = Model.detailBody(albumItems)
    compare(body.sharedSubtitle, "Tool, Justin Chancellor, Adam Jones")
    for (var i = 0; i < body.rows.length; i++)
      compare(body.rows[i].subtitle, "", "row " + i + " kept the repeated credit")
  }

  // A compilation says something different on each line, and then every line
  // is worth reading.
  function test_subtitles_that_differ_are_kept() {
    var mixed = [
      { title: "1. One", subtitle: "Aphex Twin", hint: "action_list", item_key: "e1" },
      { title: "2. Two", subtitle: "Autechre", hint: "action_list", item_key: "e2" },
      { title: "3. Three", subtitle: "Boards of Canada", hint: "action_list", item_key: "e3" }
    ]
    var body = Model.detailBody(mixed)
    compare(body.sharedSubtitle, "")
    compare(body.rows[1].subtitle, "Autechre")
  }

  function test_the_play_action_is_lifted_out_of_the_list() {
    var body = Model.detailBody(albumItems)
    compare(body.action.title, "Play Album")
    compare(body.rows.length, 4)
    compare(body.rows[0].number, 1)
    compare(body.rows[0].title, "Vicarious")
  }

  // Roon labels an artist "2 Albums" in the subtitle, so our own count line
  // underneath was the same fact in two wordings.
  function test_the_count_line_defers_to_roons_own() {
    var albumRows = Model.detailBody(albumItems).rows
    var artistRows = Model.detailBody(artistItems).rows
    compare(Model.detailCount("2 Albums", artistRows, true), "")
    compare(Model.detailCount("1 Album", artistRows, true), "")
    compare(Model.detailCount("Tool", albumRows, false), "4 tracks")
    compare(Model.detailCount("", [albumRows[0]], false), "1 track")
    compare(Model.detailCount("", [], false), "")
  }

  function test_an_artist_shows_records_and_an_album_shows_tracks() {
    compare(Model.detailIsGrid(Model.detailBody(artistItems).rows), true)
    compare(Model.detailIsGrid(Model.detailBody(albumItems).rows), false)
  }

  // A level with no leading action must not lose its first row to the split.
  // The glyph column earns its place when the glyphs differ and not otherwise.
  function test_a_glyph_column_only_appears_when_it_says_something() {
    var categories = [
      { title: "Artists", hint: "list", item_key: "c1" },
      { title: "Albums", hint: "list", item_key: "c2" },
      { title: "Tracks", hint: "list", item_key: "c3" }
    ]
    verify(Model.glyphsDiffer(categories), "categories all drew the same glyph")
    verify(!Model.glyphsDiffer(Model.detailBody(albumItems).rows.map(function (r) {
      return r.item
    })), "a track list drew a column of different glyphs")
    verify(!Model.glyphsDiffer([]))
  }

  function test_a_level_without_an_action_keeps_every_row() {
    var body = Model.detailBody([
      { title: "1. Only", subtitle: "", hint: "action_list", item_key: "d1" }
    ])
    compare(body.action, null)
    compare(body.rows.length, 1)
  }
}
