.pragma library

// Pure helpers shared by the service, the bar widget and the browser.
// Keeping them here means the QML files stay declarative and the logic
// stays testable with plain `qmljs`/`node`-style reasoning.

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// Roon reports durations in whole seconds; render them the way a transport
// bar does — m:ss, and h:mm:ss only once an hour is actually on the clock.
function duration(seconds) {
  var total = Math.max(0, Math.round(seconds || 0))
  var s = total % 60
  var m = Math.floor(total / 60) % 60
  var h = Math.floor(total / 3600)
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return h > 0 ? h + ":" + pad(m) + ":" + pad(s) : m + ":" + pad(s)
}

// Every glyph below was checked against JetBrainsMono Nerd Font AND against
// what the codepoint actually depicts. Picking Material Design codepoints
// from memory is how you end up shipping a pizza for "stopped".
var GLYPH = {
  music:       "󰝚",     // nf-md-music
  play:        "󰐊",
  pause:       "󰏤",
  previous:    "󰒮",
  next:        "󰒭",
  volume:      "󰕾",
  muted:       "󰝟",
  speaker:     "󰓃",
  shuffle:     "󰒝",
  shuffleOff:  "󰒞",
  repeat:      "󰑖",
  repeatOne:   "󰑘",
  repeatOff:   "󰑗",
  chevron:     "󰅂",
  magnify:     "󰍉",
  folder:      "󰉋",
  album:       "󰃡",
  artist:      "󰪤",
  playlist:    "󰲹",
  radio:       "󰐻",     // Roon Radio, when the queue runs out
  genre:       "󰓹",
  home:        "󰋜",
  history:     "󰋚",
  heart:       "󰋑",
  disc:        "󰭘",
  star:        "󰓎",
  queue:       "󰗢",
  cloud:       "󰅣",     // streaming catalogue
  harddisk:    "󰋊",     // already in the library
  link:        "󰌷",     // join this output to the group
  linkOff:     "󰌸",     // drop it out again
  transfer:    "󰜴",     // send playback to another room
  standby:     "󰒲",     // put an endpoint to sleep
  outputs:     "󰓄",     // a zone with more than one output
  chevronDown: "󰅀",     // an open disclosure
  close:       "󰅖",     // dismiss
  settings:    "󰒓",     // preferences
  more:        "󰇙",     // the rest of an item's actions
  heartOff:    "󰋕"      // not in the plugin's list yet
}

// The bar shows *what this is*, not *what a click will do* — a click opens
// the panel now, so an action glyph there would be a lie.
function barGlyph() {
  return GLYPH.music
}

function playPauseGlyph(playing) {
  return playing ? GLYPH.pause : GLYPH.play
}

function zoneGlyph() {
  return GLYPH.speaker
}

function shuffleGlyph(on) {
  return on ? GLYPH.shuffle : GLYPH.shuffleOff
}

function loopGlyph(mode) {
  if (mode === "loop") return GLYPH.repeat
  if (mode === "loop_one") return GLYPH.repeatOne
  return GLYPH.repeatOff
}

function nextLoopMode(mode) {
  if (mode === "disabled") return "loop"
  if (mode === "loop") return "loop_one"
  return "disabled"
}

// Roon does not tag rows by kind, so match on the title the core gives the
// top-level categories. Anything unrecognised falls back to a folder.
function rootGlyph(title) {
  var name = String(title || "").toLowerCase()
  if (name.indexOf("search") !== -1) return GLYPH.magnify
  if (name.indexOf("artist") !== -1 || name.indexOf("composer") !== -1) return GLYPH.artist
  if (name.indexOf("album") !== -1) return GLYPH.album
  if (name.indexOf("playlist") !== -1) return GLYPH.playlist
  if (name.indexOf("radio") !== -1) return GLYPH.radio
  if (name.indexOf("genre") !== -1 || name.indexOf("tag") !== -1) return GLYPH.genre
  if (name.indexOf("track") !== -1 || name.indexOf("song") !== -1) return GLYPH.disc
  if (name.indexOf("history") !== -1 || name.indexOf("recent") !== -1) return GLYPH.history
  if (name.indexOf("favorite") !== -1 || name.indexOf("favourite") !== -1) return GLYPH.heart
  if (name.indexOf("library") !== -1 || name.indexOf("overview") !== -1) return GLYPH.home
  return GLYPH.folder
}

function zoneById(zones, zoneId) {
  if (!zoneId) return null
  for (var i = 0; i < zones.length; i++) {
    if (zones[i].zone_id === zoneId) return zones[i]
  }
  return null
}

// The zone the user most likely means when they haven't picked one: the
// zone they pinned if it still exists, else whatever is actually playing,
// else the first zone the core reported.
function resolveActiveZone(zones, preferredId) {
  if (!zones || zones.length === 0) return null
  var preferred = zoneById(zones, preferredId)
  if (preferred) return preferred
  for (var i = 0; i < zones.length; i++) {
    if (zones[i].state === "playing" || zones[i].state === "loading") return zones[i]
  }
  for (var j = 0; j < zones.length; j++) {
    if (zones[j].title) return zones[j]
  }
  return zones[0]
}

// A zone can span several grouped outputs. Volume is per-output, so drive
// the first output that actually has a volume control and let the rest
// follow Roon's own grouping behaviour.
function primaryOutput(zone) {
  if (!zone || !zone.outputs || zone.outputs.length === 0) return null
  for (var i = 0; i < zone.outputs.length; i++) {
    if (zone.outputs[i].volume) return zone.outputs[i]
  }
  return zone.outputs[0]
}

function zoneVolumePercent(zone) {
  var output = primaryOutput(zone)
  return output && output.volume ? output.volume.percent : -1
}

function zoneMuted(zone) {
  var output = primaryOutput(zone)
  return !!(output && output.volume && output.volume.is_muted)
}

function zoneLabel(zone) {
  if (!zone) return ""
  return zone.display_name || "Zone"
}

function nowPlayingLabel(zone) {
  if (!zone || !zone.title) return ""
  return zone.artist ? zone.title + "  ·  " + zone.artist : zone.title
}

function progressFraction(zone) {
  if (!zone || !zone.length) return 0
  return clamp((zone.seek_position || 0) / zone.length, 0, 1)
}

// Browse rows Roon marks as headers are captions, not destinations; the
// cursor has to skip them or Enter lands on nothing.
function isSelectable(item) {
  return !!item && item.hint !== "header" && !!item.item_key
}

function firstSelectableIndex(items, from, direction) {
  if (!items || items.length === 0) return -1
  var step = direction < 0 ? -1 : 1
  for (var i = from; i >= 0 && i < items.length; i += step) {
    if (isSelectable(items[i])) return i
  }
  return -1
}

function itemGlyph(item) {
  if (!item) return ""
  if (item.input_prompt) return GLYPH.magnify
  if (item.hint === "action") return GLYPH.play
  if (item.hint === "action_list") return GLYPH.queue
  // A category row gets the same mark the nav rail gives that category. The
  // rail has had icons since the first version and the content pane beside it
  // had none, which is most of why Artists / Albums / Tracks read as one
  // undifferentiated wall of words.
  if (item.hint === "list" && !item.art) {
    var glyph = rootGlyph(item.title)
    if (glyph !== GLYPH.folder) return glyph
  }
  // Placeholder for a row with no artwork. Not a chevron — the row already
  // carries one on the right as its navigation affordance.
  return GLYPH.music
}

// A level is worth showing as a grid when it is mostly artwork: album and
// artist lists read as covers, whereas tracks, actions and settings do not.
// Judged from the rows themselves rather than the level title, so it works
// for Qobuz, Tidal and anything else the core exposes.
function prefersGrid(items) {
  if (!items || items.length < 6) return false
  var withArt = 0
  var selectable = 0
  for (var i = 0; i < items.length; i++) {
    if (!isSelectable(items[i])) continue
    selectable++
    if (items[i].art) withArt++
  }
  return selectable >= 6 && withArt / selectable >= 0.6
}

// Roon returns a flat count for the level; show it so a 788-album list says
// so rather than looking like it starts and ends with numeric titles.
function levelCount(browse) {
  if (!browse || !browse.count) return ""
  return browse.count === 1 ? "1 item" : browse.count.toLocaleString() + " items"
}

// Setup guidance, keyed off the bridge's status. Returns null once there is
// nothing left for the user to do.
function setupSteps(status) {
  var state = status ? status.state : "starting"
  if (state === "ready") return null

  if (state === "waiting_authorization") {
    return {
      heading: "Authorize Omarchy in Roon",
      blurb: "Roon only accepts extensions you approve by hand. This is a one-time step.",
      steps: [
        "Open Roon on any device — desktop, tablet or phone",
        "Go to Settings → Extensions",
        "Find “Omarchy” and press Enable"
      ],
      waiting: "Waiting for approval…",
      tone: "action"
    }
  }

  if (state === "installing") {
    return {
      heading: "Setting up",
      blurb: "Building the small Python environment the Roon connection runs in. "
        + "This happens once and needs the network.",
      steps: [],
      waiting: "Installing…",
      tone: "busy"
    }
  }

  if (state === "discovering") {
    return {
      heading: "Looking for your Roon core",
      blurb: "Searching the local network.",
      steps: [],
      waiting: "Discovering…",
      tone: "busy"
    }
  }

  if (state === "connecting") {
    return {
      heading: "Connecting",
      blurb: "Reaching " + ((status && status.host) || "the core") + ".",
      steps: [],
      waiting: "Connecting…",
      tone: "busy"
    }
  }

  var message = (status && status.message) || ""
  if (message.indexOf("Setup failed") !== -1) {
    return {
      heading: "Setup did not complete",
      blurb: message,
      steps: ["Run install.sh from the plugin folder to see the error",
              "Then restart the shell"],
      waiting: "",
      tone: "error"
    }
  }

  if (message.indexOf("not installed") !== -1) {
    return {
      heading: "Finish installing the bridge",
      blurb: "The Roon connection runs in its own Python environment, which has not been built yet.",
      steps: ["Run install.sh from the plugin folder", "Then restart the shell"],
      waiting: "",
      tone: "error"
    }
  }

  if (message.indexOf("No Roon core") !== -1) {
    return {
      heading: "No Roon core found",
      blurb: "Discovery uses multicast, which does not cross VPNs, VLANs or a NAT'd VM.",
      steps: [
        "Check the core is powered on and on this network",
        "Or set the core's address in the widget settings"
      ],
      waiting: "Retrying…",
      tone: "error"
    }
  }

  return {
    heading: "Roon is not connected",
    blurb: message,
    steps: [],
    waiting: "Retrying…",
    tone: "error"
  }
}

// Elapsed time in the shape a "recently played" list wants: coarse and
// glanceable, not a timestamp.
function ago(seconds) {
  var delta = Math.max(0, Math.floor(Date.now() / 1000) - (seconds || 0))
  if (delta < 90) return "just now"
  if (delta < 3600) return Math.round(delta / 60) + "m ago"
  if (delta < 86400) return Math.round(delta / 3600) + "h ago"
  var days = Math.round(delta / 86400)
  return days === 1 ? "yesterday" : days + "d ago"
}

// Only worth badging rows when a list holds both kinds; a Qobuz browse where
// every row is streaming learns nobody anything.
function levelIsMixed(items) {
  var seenCatalog = false, seenLibrary = false
  for (var i = 0; i < items.length; i++) {
    if (!isSelectable(items[i])) continue
    if (items[i].catalog) seenCatalog = true
    else seenLibrary = true
    if (seenCatalog && seenLibrary) return true
  }
  return false
}

// A zone is grouped when Roon is driving more than one output through it.
function isGrouped(zone) {
  return !!zone && !!zone.outputs && zone.outputs.length > 1
}

// Outputs the active zone could pick up, gathered from what each of its own
// outputs says it can group with. Roon answers per output, so the union is
// what the panel offers.
function groupableOutputIds(zone) {
  var seen = {}
  var out = []
  var outputs = (zone && zone.outputs) || []
  for (var i = 0; i < outputs.length; i++) {
    var ids = outputs[i].can_group_with_output_ids || []
    for (var j = 0; j < ids.length; j++) {
      // Each output lists its siblings too; the panel wants only outputs the
      // zone has not already picked up.
      if (seen[ids[j]] || zoneHasOutput(zone, ids[j])) continue
      seen[ids[j]] = true
      out.push(ids[j])
    }
  }
  return out
}

function zoneHasOutput(zone, outputId) {
  var outputs = (zone && zone.outputs) || []
  for (var i = 0; i < outputs.length; i++) if (outputs[i].output_id === outputId) return true
  return false
}

// Every output id belonging to a zone, which is what group/ungroup take.
function outputIds(zone) {
  var out = []
  var outputs = (zone && zone.outputs) || []
  for (var i = 0; i < outputs.length; i++) out.push(outputs[i].output_id)
  return out
}

// Roon's queue starts with the track that is playing, which is not what
// "up next" means. Drop it so the panel shows what follows.
function queueUpcoming(items, currentTitle) {
  if (!items || items.length === 0) return []
  var current = String(currentTitle || "")
  return items[0].title === current && current !== "" ? items.slice(1) : items
}

// "11 queued" is a number; "1h 24m left" is an answer.
function queueRemaining(seconds) {
  var total = Math.max(0, Math.round(seconds || 0))
  if (total < 60) return ""
  var h = Math.floor(total / 3600)
  var m = Math.round((total % 3600) / 60)
  if (h > 0) return h + "h " + m + "m left"
  return m + "m left"
}

function queueSummary(items, currentTitle) {
  var upcoming = queueUpcoming(items, currentTitle)
  if (upcoming.length === 0) return ""
  var next = upcoming[0]
  var label = next.title || ""
  if (next.artist) label += "  ·  " + next.artist
  return label
}

function statusLine(status) {
  if (!status) return "Starting…"
  switch (status.state) {
    case "discovering": return "Looking for a Roon core…"
    case "connecting": return "Connecting to " + (status.host || "core") + "…"
    case "waiting_authorization": return "Enable “Omarchy” in Roon → Settings → Extensions"
    case "ready": return "Connected to " + (status.core || "Roon")
    case "error": return status.message || "Roon error"
    default: return status.message || "Starting…"
  }
}

// The keyboard reference behind `?`.
//
// The footer used to carry all of this as one elided line, which meant the
// tail of it — the half you had not memorised — was the half cut off. Kept
// here rather than in the QML so the overlay and the footer cannot drift, and
// so the set is testable.
function shortcutGroups(gridMode) {
  return [
    {
      title: "Move",
      keys: [
        { keys: gridMode ? ["←", "→", "↑", "↓"] : ["j", "k"], text: "Move the cursor" },
        { keys: ["tab"], text: "Switch between the two panes" },
        { keys: ["g"], text: "Jump to the category list" },
        { keys: ["1–9"], text: "Open the nth row directly" }
      ]
    },
    {
      title: "Open",
      keys: [
        { keys: ["enter"], text: "Open, or run the highlighted action" },
        { keys: ["backspace"], text: "Back one level" },
        { keys: ["esc"], text: "Close the browser" }
      ]
    },
    {
      title: "Find",
      keys: [
        { keys: ["s"], text: "Search the whole library and Qobuz" },
        { keys: ["/"], text: "Filter what is already on screen" },
        { keys: ["v"], text: "Switch between grid and list" },
        { keys: ["alt A–Z"], text: "Jump to a letter in a long list" },
        { keys: ["x"], text: "Clear the recently-played log" },
        { keys: ["f"], text: "Favourite the album you are on" }
      ]
    },
    {
      title: "Playback",
      keys: [
        { keys: ["p"], text: "Play or pause" },
        { keys: ["[", "]"], text: "Previous or next track" },
        { keys: [",", "."], text: "Back or forward ten seconds" },
        { keys: ["-", "="], text: "Volume down or up" },
        { keys: ["m"], text: "Mute" },
        { keys: ["z"], text: "Play in the next room" }
      ]
    }
  ]
}

// -- detail levels ---------------------------------------------------------
//
// Roon gives a level its own title, subtitle, cover and count, and every one
// of those was being discarded — so an album, the screen you are on when you
// decide whether to press play, rendered as a plain row list with "Play Album"
// as row one. The level's cover is the signal: only an album or an artist has
// one, so its presence is what promotes a level to a detail screen.

function isDetailLevel(browse) {
  return !!(browse && browse.art)
}

// "1. Vicarious" -> 1. Roon bakes the index into the title; a number column
// reads better than a numbered sentence, and the sort order is already Roon's.
function trackNumber(title) {
  var match = /^\s*(\d{1,3})\.\s+/.exec(title || "")
  return match ? parseInt(match[1], 10) : 0
}

function stripTrackNumber(title) {
  return String(title || "").replace(/^\s*\d{1,3}\.\s+/, "")
}

// Twelve rows carrying the identical five-name credit string is not
// information, it is noise with a scrollbar. If most of the level says the
// same thing, none of it needs to.
function repeatedSubtitle(items) {
  var counts = {}
  var total = 0
  var best = ""
  var bestCount = 0
  for (var i = 0; i < (items || []).length; i++) {
    var subtitle = items[i].subtitle || ""
    if (!subtitle) continue
    total++
    counts[subtitle] = (counts[subtitle] || 0) + 1
    if (counts[subtitle] > bestCount) {
      bestCount = counts[subtitle]
      best = subtitle
    }
  }
  return total >= 3 && bestCount / total >= 0.6 ? best : ""
}

// Splits a detail level into its one primary action and everything else.
// Roon puts "Play Album" / "Play Artist" first and unnumbered; the rest are
// the tracks of the record or the records of the artist.
function detailBody(items) {
  var rows = (items || []).slice()
  var action = null
  if (rows.length && rows[0].hint === "action_list" && !trackNumber(rows[0].title)) {
    action = rows[0]
    rows = rows.slice(1)
  }
  var noise = repeatedSubtitle(rows)
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    out.push({
      item: row,
      index: i,
      number: trackNumber(row.title),
      title: stripTrackNumber(row.title),
      subtitle: row.subtitle === noise ? "" : (row.subtitle || ""),
      art: row.art || ""
    })
  }
  return { action: action, rows: out, sharedSubtitle: noise }
}

// Roon's own subtitle for an artist is already a count ("2 Albums"), so
// adding ours underneath prints the same fact twice in two wordings.
function detailCount(subtitle, rows, asGrid) {
  var n = (rows || []).length
  if (n === 0) return ""
  if (/^\s*\d+\s+\S/.test(subtitle || "")) return ""
  return asGrid
    ? n + (n === 1 ? " release" : " releases")
    : n + (n === 1 ? " track" : " tracks")
}

// A detail level whose children carry covers is an artist: show the records.
// One whose children are numbered is an album: show the tracks.
function detailIsGrid(rows) {
  if (!rows || rows.length === 0) return false
  var withArt = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].art) withArt++
  return withArt / rows.length >= 0.6
}

// An empty pane is where a product either explains itself or looks broken.
// One sentence used to stand in for every one of them — a queue with nothing
// in it, a log just cleared, a search that found nothing — and it was only
// correct in the first case.
//
// Each returns a glyph, a line saying what is empty, and a line saying what
// would fill it, because "no favourites yet" without "press f on an album" is
// only half an answer.
function emptyState(mode, filterText, query) {
  if (filterText) {
    return { glyph: GLYPH.magnify,
             title: "Nothing here matches \u201c" + filterText + "\u201d",
             hint: "Esc clears the filter" }
  }
  switch (mode) {
    case "queue":
      return { glyph: GLYPH.queue,
               title: "Nothing queued after this track",
               hint: "Add Next and Queue, on any album, fill this" }
    case "history":
      return { glyph: GLYPH.history,
               title: "Nothing played yet",
               hint: "Records you listen to are remembered here, newest first" }
    case "favourites":
      return { glyph: GLYPH.heartOff,
               title: "No favourites yet",
               hint: "Press f on an album to keep it here" }
    case "search":
      return query
        ? { glyph: GLYPH.magnify,
            title: "Roon found nothing for \u201c" + query + "\u201d",
            hint: "Search covers your library and the catalogues you subscribe to" }
        : { glyph: GLYPH.magnify, title: "Search Roon", hint: "Type a name and press enter" }
    case "level":
      return { glyph: GLYPH.folder, title: "Nothing in here", hint: "" }
    default:
      return { glyph: GLYPH.home, title: "Choose a category", hint: "" }
  }
}

// Whether a leading glyph column tells the reader anything on this level.
//
// A list of tracks gives every row the same glyph, and a column of identical
// marks is noise with a scrollbar — which is why the column was tied to
// artwork and category rows got nothing at all. The honest test is whether
// the glyphs actually differ.
function glyphsDiffer(items) {
  var first = ""
  for (var i = 0; i < (items || []).length; i++) {
    if (!isSelectable(items[i])) continue
    var glyph = itemGlyph(items[i])
    if (first === "") first = glyph
    else if (glyph !== first) return true
  }
  return false
}
