import QtQuick
import Quickshell
import Quickshell.Io
import "RoonModel.js" as Model

// Headless singleton owning the one Roon connection the shell needs.
//
// QML has no WebSocket module here, and Roon speaks its own framed protocol,
// so the connection lives in bridge/roon_bridge.py and this service talks to
// it over stdio in newline-delimited JSON. One long-lived child process per
// shell — never one per widget — so grouping, browse position and the auth
// token all stay coherent no matter how many bars are on screen.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Set by the bar widget from its shell.json entry. Empty means "discover".
  property string coreHost: ""

  // Whether picking Play Now / Add Next / Queue dismisses the browser.
  // Set from the widget's shell.json entry, same route as coreHost.
  property bool closeBrowserAfterAction: true

  // Asking endpoints for their stream format means LAN traffic to third-party
  // devices, so it is a choice rather than an assumption.
  property bool showOutputFormat: true

  // Qt exposes no prefers-reduced-motion, and this component sits on screen
  // all day, so it is asked for rather than guessed. Off means every
  // decorative animation in the plugin stops — marquee, pulses, fades.
  property bool reduceMotion: false

  // Recording what you listen to is the plugin's own choice, not Roon's, so
  // it is switchable and clearable.
  property bool keepHistory: true

  // Volume moved from the keyboard is otherwise invisible: nothing is on
  // screen, and the only feedback is the music itself. On by default for that
  // reason. Track changes are the opposite — an OSD on every track all day is
  // a thing you would want to turn off, so it starts off.
  property bool volumeOsd: true
  property bool trackOsd: false
  onKeepHistoryChanged: send({ cmd: "history_enabled", on: keepHistory })
  onShowOutputFormatChanged: if (bridge.running) restart()

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.jesse-chelin.roon"

  readonly property string pluginDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir).replace(/\/$/, "") : defaultPluginDir
  readonly property string defaultPluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.jesse-chelin.roon"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-roon"
  readonly property string venvPython: stateDir + "/venv/bin/python"
  readonly property string bridgePath: pluginDir + "/bridge/roon_bridge.py"

  // --- state pushed up from the bridge --------------------------------------

  property var status: ({ state: "starting", message: "" })
  property var zones: []
  property string preferredZoneId: ""
  property var browse: ({ title: "", items: [], crumbs: [], level: 0, count: 0, offset: 0 })
  property var roots: []

  // zone_id -> what that zone's physical endpoint reports it is decoding.
  // Roon does not carry format information, so this comes from the devices
  // themselves; see bridge/endpoints.py.
  property var endpoints: ({})

  // Roon exposes no play history of any kind, so the bridge keeps its own
  // from the track changes it already observes. Ours, not Roon's.
  property var history: []

  // The plugin's own favourites. Roon's extension API has none — there is no
  // such hierarchy in the browse tree and an album's actions are Play Now,
  // Add Next, Queue and Start Radio — so this list is ours and says so.
  property var favourites: []

  // Where each initial letter starts in the level on screen. The bridge only
  // sends this for a level it could load whole, so its presence is also the
  // signal that the browser is holding every row.
  property var letters: []

  // Whether the log has answered yet, as distinct from having answered
  // "nothing". The browser opens on Recently played, and on a first run
  // that has to mean "empty" rather than "not asked yet".
  property bool historyLoaded: false

  // The upcoming tracks for one zone, streamed by the core.
  property var queue: []
  property string queueZoneId: ""
  property string lastMessage: ""

  // A failure the user has not seen yet. Errors used to be a 3.2s toast in the
  // browser and nowhere else, so anything that failed with the panel open, or
  // the browser shut, failed in silence. This holds until acknowledged.
  property string lastError: ""
  property double lastErrorAt: 0

  function noteError(text) {
    if (!text) return
    root.lastError = text
    root.lastErrorAt = Date.now()
  }

  function dismissError() {
    root.lastError = ""
    root.lastErrorAt = 0
  }
  property string rawDump: ""
  property bool bridgeRunning: false

  readonly property bool ready: status && status.state === "ready"
  readonly property bool needsAuthorization: status && status.state === "waiting_authorization"
  readonly property var activeZone: Model.resolveActiveZone(zones, preferredZoneId)
  readonly property bool hasZones: zones.length > 0
  readonly property string statusLine: Model.statusLine(status)

  signal messageReceived(string text, bool isError)
  signal raiseRequested()

  // --- commands -------------------------------------------------------------

  property int nextRequestId: 1

  function send(command) {
    if (!bridge.running) return false
    command.id = nextRequestId++
    bridge.write(JSON.stringify(command) + "\n")
    return true
  }

  // The endpoint's reading for a zone, or "" when nothing answered. This is
  // the *output* format — bit-perfect for a RAAT endpoint, but Roon's own
  // transport encoding for something it transcodes to, like Sonos.
  function outputFormat(zone) {
    if (!zone || !endpoints) return ""
    var entry = endpoints[zone.zone_id]
    return entry && entry.display ? entry.display : ""
  }

  function outputDevice(zone) {
    if (!zone || !endpoints) return ""
    var entry = endpoints[zone.zone_id]
    return entry && entry.device ? entry.device : ""
  }

  // Roon serves a long level a page at a time. The UI wants one growing list,
  // not a series of replacements — replacing is why opening Albums appeared to
  // jump from "8 Miles High" to "Black Star" on its own.
  function mergeBrowse(current, incoming) {
    if (!incoming || !incoming.offset) return incoming
    if (!current || current.level !== incoming.level || current.title !== incoming.title)
      return incoming
    var existing = current.items || []
    if (incoming.offset !== existing.length) return incoming

    var merged = {}
    for (var key in incoming) merged[key] = incoming[key]
    merged.items = existing.concat(incoming.items || [])
    // The merged array starts at zero, and `appended` tells the browser this
    // is more of the same level rather than a new one to reset onto.
    merged.offset = 0
    merged.appended = true
    return merged
  }

  function zoneTarget(zoneId) {
    if (zoneId) return zoneId
    return activeZone ? activeZone.zone_id : ""
  }

  function control(action, zoneId) {
    var zone = zoneTarget(zoneId)
    if (!zone) return false
    // Acting on a zone pins it. Without this, pausing the only playing zone
    // would immediately hand "active" to a different one, and the next click
    // would control something the user never chose.
    preferredZoneId = zone
    return send({ cmd: "control", zone: zone, action: action })
  }

  function playPause(zoneId) { return control("playpause", zoneId) }
  function next(zoneId) { return control("next", zoneId) }
  function previous(zoneId) { return control("previous", zoneId) }

  function seek(seconds, zoneId, method) {
    var zone = zoneTarget(zoneId)
    if (!zone) return false
    return send({ cmd: "seek", zone: zone, seconds: Math.round(seconds), method: method || "absolute" })
  }

  function toggleShuffle(zoneId) {
    var zone = Model.zoneById(zones, zoneTarget(zoneId)) || activeZone
    if (!zone) return false
    return send({ cmd: "shuffle", zone: zone.zone_id, on: !zone.shuffle })
  }

  // Roon Radio: keep playing something sensible when the queue runs dry. It
  // arrives in every zone payload and had no control anywhere.
  function toggleAutoRadio(zoneId) {
    var zone = Model.zoneById(zones, zoneTarget(zoneId)) || activeZone
    if (!zone) return false
    return send({ cmd: "auto_radio", zone: zone.zone_id, on: !zone.auto_radio })
  }

  function cycleLoop(zoneId) {
    var zone = Model.zoneById(zones, zoneTarget(zoneId)) || activeZone
    if (!zone) return false
    return send({ cmd: "repeat", zone: zone.zone_id, mode: Model.nextLoopMode(zone.loop) })
  }

  // Volume is the one control the user drags, and a drag emits a value on
  // every mouse move. Sending each one costs a Roon round trip, so the knob
  // used to fight the stale value coming back and felt like it was lagging.
  //
  // Two things fix it: show the requested value immediately (`volumeOverrides`)
  // and send at most one command per tick (`volumeFlush`), always the newest.
  property var volumeOverrides: ({})
  property var volumePending: ({})

  // How long an unconfirmed override stands before we accept that the core
  // disagreed and fall back to whatever it reports.
  readonly property int volumeOverrideGrace: 2000

  function volumePercentFor(zone) {
    var output = Model.primaryOutput(zone)
    if (!output) return -1
    var override = volumeOverrides[output.output_id]
    if (override !== undefined) return override.percent
    return output.volume ? output.volume.percent : -1
  }

  function queueVolume(outputId, percent) {
    var value = Math.max(0, Math.min(100, Math.round(percent)))

    var overrides = ({})
    for (var k in volumeOverrides) overrides[k] = volumeOverrides[k]
    overrides[outputId] = { percent: value, at: Date.now() }
    volumeOverrides = overrides

    var pending = ({})
    for (var p in volumePending) pending[p] = volumePending[p]
    pending[outputId] = value
    volumePending = pending

    if (!volumeFlush.running) {
      flushVolume()          // lead with the first move so it feels instant
      volumeFlush.start()
    }
    // Every volume path funnels through here — the bar's wheel, the two
    // sliders, the keyboard, the per-output faders — so the OSD hangs off this
    // one place rather than off each caller.
    if (root.volumeOsd) {
      var zone = Model.resolveActiveZone(root.zones, root.preferredZoneId)
      root.showOsd("volume", zone ? Model.zoneLabel(zone) : "Roon", value)
    }
    return true
  }

  function flushVolume() {
    var pending = volumePending
    var any = false
    for (var outputId in pending) {
      send({ cmd: "volume", output: outputId, percent: pending[outputId] })
      any = true
    }
    volumePending = ({})
    return any
  }

  function setVolume(percent, zoneId) {
    var output = Model.primaryOutput(Model.zoneById(zones, zoneTarget(zoneId)) || activeZone)
    if (!output) return false
    return queueVolume(output.output_id, percent)
  }

  function stepVolume(delta, zoneId) {
    var zone = Model.zoneById(zones, zoneTarget(zoneId)) || activeZone
    var output = Model.primaryOutput(zone)
    if (!output) return false
    var current = volumePercentFor(zone)
    if (current < 0) return false
    return queueVolume(output.output_id, current + delta)
  }

  // Drop an override once the core agrees with it, or once it has stood
  // unconfirmed long enough that the core clearly is not going to.
  function reconcileVolume() {
    var next = ({})
    var changed = false
    var now = Date.now()

    for (var outputId in volumeOverrides) {
      var override = volumeOverrides[outputId]
      var reported = -1
      for (var i = 0; i < zones.length && reported < 0; i++) {
        var outputs = zones[i].outputs || []
        for (var j = 0; j < outputs.length; j++) {
          if (outputs[j].output_id === outputId && outputs[j].volume) {
            reported = outputs[j].volume.percent
            break
          }
        }
      }
      if (reported === override.percent || now - override.at > volumeOverrideGrace) {
        changed = true
        continue
      }
      next[outputId] = override
    }

    if (changed) volumeOverrides = next
  }

  onZonesChanged: reconcileVolume()

  Timer {
    id: volumeFlush
    interval: 90
    repeat: true
    onTriggered: if (!root.flushVolume()) stop()
  }

  function toggleMute(zoneId) {
    var zone = Model.zoneById(zones, zoneTarget(zoneId)) || activeZone
    var output = Model.primaryOutput(zone)
    if (!output) return false
    var muting = !Model.zoneMuted(zone)
    if (root.volumeOsd) {
      root.showOsd(muting ? "volume-muted" : "volume",
                   Model.zoneLabel(zone) + (muting ? " muted" : ""),
                   muting ? -1 : Model.zoneVolumePercent(zone))
    }
    return send({ cmd: "mute", output: output.output_id, mute: muting })
  }

  function transfer(fromZoneId, toZoneId) {
    if (!fromZoneId || !toZoneId) return false
    return send({ cmd: "transfer", from: fromZoneId, to: toZoneId })
  }

  function selectZone(zoneId) {
    preferredZoneId = zoneId || ""
    return true
  }

  function browseHome(zoneId) {
    return send({ cmd: "browse_home", zone: zoneTarget(zoneId) })
  }

  function browseItem(itemKey, userInput, zoneId) {
    if (!itemKey) return false
    var command = { cmd: "browse_item", item_key: itemKey, zone: zoneTarget(zoneId) }
    if (userInput !== undefined && userInput !== null) command.input = String(userInput)
    return send(command)
  }

  // Addressed by title: the bridge pops the browse stack to reach the top
  // level, and Roon regenerates item_keys for the level it reloads, so a key
  // captured when the nav pane was populated is already stale.
  // Searches from a fresh root every time rather than a captured item_key,
  // which Roon invalidates whenever the browse stack moves. Roon's search is
  // global: the results already include the streaming catalogue.
  function search(text, zoneId) {
    if (!text) return false
    return send({ cmd: "search", text: String(text), zone: zoneTarget(zoneId) })
  }

  // Opens a remembered album rather than leaving the user on a search page.
  function findAlbum(album, artist, zoneId) {
    if (!album) return false
    return send({
      cmd: "find_album",
      album: String(album),
      artist: String(artist || ""),
      zone: zoneTarget(zoneId)
    })
  }

  // The category list belongs to the connection, not to whoever happened to
  // open a window first. Asking only from Browser.open() meant a bridge that
  // reconnected under an already-open browser left it with an empty nav and
  // no way back except closing and reopening.
  function ensureRoots() {
    if (roots && roots.length > 0) return false
    return browseHome("")
  }

  onReadyChanged: {
    if (!ready) return
    ensureRoots()
    // Both lists are the plugin's own, kept on disk, and the browser opens
    // on one of them — so they have to be here before the first frame.
    refreshHistory()
    refreshFavourites()
  }

  // -- queue ---------------------------------------------------------------

  function refreshQueue(zoneId) {
    return send({ cmd: "queue", zone: zoneTarget(zoneId) })
  }

  function playFromQueue(queueItemId, zoneId) {
    var zone = zoneTarget(zoneId)
    if (!zone || queueItemId === undefined || queueItemId === null) return false
    return send({ cmd: "play_from_queue", zone: zone, queue_item_id: queueItemId })
  }

  // -- outputs and grouping -------------------------------------------------

  function setOutputVolume(outputId, percent) {
    if (!outputId) return false
    return queueVolume(outputId, percent)
  }

  function toggleOutputMute(outputId) {
    var output = outputById(outputId)
    if (!output || !output.volume) return false
    return send({ cmd: "mute", output: outputId, mute: !output.volume.is_muted })
  }

  function outputById(outputId) {
    for (var i = 0; i < zones.length; i++) {
      var outputs = zones[i].outputs || []
      for (var j = 0; j < outputs.length; j++) {
        if (outputs[j].output_id === outputId) return outputs[j]
      }
    }
    return null
  }

  function zoneForOutput(outputId) {
    for (var i = 0; i < zones.length; i++) {
      if (Model.zoneHasOutput(zones[i], outputId)) return zones[i]
    }
    return null
  }

  // Roon takes the whole set, existing members included, so joining means
  // sending the zone's own outputs plus the newcomer.
  function addOutputToZone(outputId, zoneId) {
    var zone = Model.zoneById(zones, zoneTarget(zoneId)) || activeZone
    if (!zone || !outputId) return false
    var ids = Model.outputIds(zone)
    if (ids.indexOf(outputId) !== -1) return false
    ids.push(outputId)
    return send({ cmd: "group", outputs: ids })
  }

  function removeOutputFromZone(outputId) {
    if (!outputId) return false
    return send({ cmd: "ungroup", outputs: [outputId] })
  }

  function standby(outputId) {
    if (!outputId) return false
    return send({ cmd: "standby", output: outputId })
  }

  function refreshHistory() { return send({ cmd: "history" }) }
  function refreshFavourites() { return send({ cmd: "favourites" }) }
  function clearHistory() { return send({ cmd: "history_clear" }) }

  function toggleFavourite(album, artist, art) {
    if (!album) return false
    return send({
      cmd: "favourite_toggle",
      album: String(album),
      artist: String(artist || ""),
      art: String(art || "")
    })
  }

  function clearFavourites() { return send({ cmd: "favourites_clear" }) }

  // True when this record is already in the plugin's list. Matched on cover
  // first and first-credited artist second, the same identity the history and
  // the bridge use, so the three cannot disagree about what one album is.
  function isFavourite(album, artist, art) {
    var wanted = String(album || "").trim().toLowerCase()
    if (!wanted) return false
    var wantedArt = String(art || "")
    var wantedArtist = String(artist || "").split("/")[0].trim().toLowerCase()
    for (var i = 0; i < root.favourites.length; i++) {
      var f = root.favourites[i]
      if (String(f.album || "").trim().toLowerCase() !== wanted) continue
      if (wantedArt && f.art) { if (f.art === wantedArt) return true; continue }
      if (String(f.artist || "").split("/")[0].trim().toLowerCase() === wantedArtist) return true
    }
    return false
  }

  // Runs an item's Play Now without making the user walk the action menu.
  function playDefault(itemKey, label, zoneId) {
    if (!itemKey) return false
    return send({
      cmd: "play_default",
      item_key: String(itemKey),
      label: String(label || ""),
      zone: zoneTarget(zoneId)
    })
  }

  function browseRoot(title, index, zoneId) {
    return send({
      cmd: "browse_root",
      title: title || "",
      index: index === undefined ? -1 : index,
      zone: zoneTarget(zoneId)
    })
  }

  function browseBack() { return send({ cmd: "browse_back" }) }
  function browsePage(offset) { return send({ cmd: "browse_page", offset: Math.max(0, offset) }) }
  function refresh() { return send({ cmd: "refresh" }) }

  function restart() {
    bridge.running = false
    restartTimer.restart()
  }

  // --- bridge process --------------------------------------------------------

  // Touch $XDG_STATE_HOME/omarchy-roon/mock to make the bridge serve
  // fabricated zones and a fake library. That is the only way to work on
  // this UI from a machine that cannot see a Roon core. Writing one of
  // "waiting", "nocore" or "discovering" into that file also pins the
  // connection state, so the setup screens can be reviewed on demand.
  property bool mockMode: false
  property string mockState: "ready"

  function bridgeCommand() {
    var argv = [venvPython, bridgePath]
    if (mockMode) argv.push("--mock", "--mock-state", mockState)
    else if (coreHost) argv.push("--host", coreHost)
    if (!showOutputFormat) argv.push("--no-endpoints")
    return argv
  }

  function handleEvent(payload) {
    switch (payload.type) {
      case "status":
        // A core that went away and came back is a new session: it mints
        // fresh browse item_keys, so every key we hold is dead. Dropping the
        // cached level and roots here is what makes the browser refetch
        // instead of sending keys the core no longer recognises.
        if (payload.state !== "ready" && root.ready) {
          root.roots = []
          root.browse = { items: [], crumbs: [], title: "" }
          root.letters = []
          root.queue = []
          root.queueZoneId = ""
        }
        root.status = payload
        // Any state that is not an error supersedes one. Clearing only on
        // "ready" left a stale "Lost the Roon core" strip sitting above a card
        // that had already moved on to asking for authorization — two answers
        // to the same question, one of them out of date.
        if (payload.state === "error") root.noteError(payload.message || "Roon error")
        else root.dismissError()
        break
      case "zones":
        var previous = root.activeZone
        root.zones = payload.zones || []
        if (root.trackOsd) root.announceTrack(previous, root.activeZone)
        break
      case "endpoints":
        root.endpoints = payload.data || ({})
        break
      case "active_zone":
        // A media key acted on a room; follow it, so the panel is showing the
        // same thing the desktop just controlled.
        if (payload.zone_id) root.preferredZoneId = payload.zone_id
        break
      case "raise":
        // A desktop client asked to see the player — MPRIS Raise. Show the
        // library rather than the panel: "show me the app" means the big one.
        if (root.shell && typeof root.shell.call === "function")
          root.shell.call("io.github.jesse-chelin.roon", "open", "{}")
        root.raiseRequested()
        break
      case "queue":
        root.queueZoneId = payload.zone_id || ""
        root.queue = payload.items || []
        break
      case "history":
        root.history = payload.items || []
        root.historyLoaded = true
        break
      case "favourites":
        root.favourites = payload.items || []
        break
      case "letters":
        root.letters = payload.items || []
        break
      case "roots":
        root.roots = payload.items || []
        break
      case "raw":
        root.rawDump = JSON.stringify(payload.data, null, 2)
        break
      case "browse":
        if (!payload.appended) root.letters = []
        // `browse` is a var property, so assigning a fresh object here is
        // what fires browseChanged() for the overlay to hang its reset on.
        root.browse = root.mergeBrowse(root.browse, payload)
        break
      case "message":
        root.lastMessage = payload.message || ""
        if (payload.is_error === true) root.noteError(payload.message || "")
        root.messageReceived(payload.message || "", payload.is_error === true)
        break
      case "error":
        // Command-level failures are surfaced but never fatal; the bridge
        // stays up and the next command is still worth trying.
        root.lastMessage = payload.message || ""
        root.noteError(payload.message || "")
        root.messageReceived(payload.message || "", true)
        break
      case "result":
        break
      default:
        break
    }
  }

  onCoreHostChanged: if (bridge.running) restart()

  Component.onCompleted: mockCheck.running = true

  // -- on-screen display ----------------------------------------------------
  //
  // Omarchy's own OSD, reached the way anything else reaches it. Deliberately
  // not a surface of our own: volume from this plugin should look exactly like
  // volume from the audio widget, because to the person watching it is the
  // same act.
  Process { id: osdProcess }

  function showOsd(icon, message, value) {
    var payload = { icon: icon, message: message, duration: 1400 }
    if (value !== undefined && value >= 0) {
      payload.value = value
      payload.max = 100
    }
    osdProcess.running = false
    osdProcess.command = ["omarchy-shell", "-q", "osd", "show", JSON.stringify(payload)]
    osdProcess.running = true
  }

  // Only the zone being listened to, only while it is playing, and only when
  // the track genuinely changed — a zone payload arrives for every seek tick.
  function announceTrack(before, after) {
    if (!after || after.state !== "playing" || !after.title) return
    if (before && before.zone_id === after.zone_id && before.title === after.title) return
    root.showOsd("music", after.artist ? after.title + " · " + after.artist : after.title, -1)
  }

  function announceVolume(zoneId) {
    if (!volumeOsd) return
    var zone = Model.zoneById(zones, zoneTarget(zoneId)) || activeZone
    if (!zone) return
    if (Model.zoneMuted(zone)) {
      root.showOsd("volume-muted", Model.zoneLabel(zone) + " muted", -1)
      return
    }
    root.showOsd("volume", Model.zoneLabel(zone), Model.zoneVolumePercent(zone))
  }

  // The bridge needs its venv. Rather than let Process fail with a bare
  // ENOENT the user can't act on, check first and say what to run.
  Process {
    id: mockCheck
    command: ["sh", "-c", "cat " + root.stateDir + "/mock 2>/dev/null || exit 1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = String(text).trim()
        root.mockState = ["waiting", "nocore", "discovering"].indexOf(value) !== -1 ? value : "ready"
      }
    }
    onExited: function(exitCode) {
      root.mockMode = exitCode === 0
      venvCheck.running = true
    }
  }

  Process {
    id: venvCheck
    command: ["test", "-x", root.venvPython]
    onExited: function(exitCode) {
      if (exitCode === 0) {
        bridge.running = true
        return
      }
      // Telling someone to go and run a script is a step that did not need to
      // exist: enabling the plugin is the consent, and this is the same script
      // the instructions used to point at. Only ever run once — a second
      // failure reports rather than loops.
      if (root.installAttempted) {
        root.status = {
          state: "error",
          message: "Setup failed — run " + root.pluginDir + "/install.sh by hand to see why"
        }
        return
      }
      root.installAttempted = true
      root.status = { state: "installing", message: "Setting up the Roon bridge…" }
      installer.running = true
    }
  }

  // First-run setup. Builds the private virtualenv the bridge needs.
  property bool installAttempted: false

  Process {
    id: installer
    command: ["bash", root.pluginDir + "/install.sh"]
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { if (line) console.warn("roon setup:", line) }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) venvCheck.running = true
      else root.status = {
        state: "error",
        message: "Setup failed (" + exitCode + ") — run " + root.pluginDir + "/install.sh to see why"
      }
    }
  }

  Process {
    id: bridge
    command: root.bridgeCommand()
    stdinEnabled: true
    running: false

    onRunningChanged: root.bridgeRunning = running

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        if (!line) return
        try {
          root.handleEvent(JSON.parse(line))
        } catch (e) {
          console.warn("roon: unparsable bridge line:", line)
        }
      }
    }

    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { if (line) console.warn("roon bridge:", line) }
    }

    onExited: function(exitCode) {
      root.bridgeRunning = false
      root.zones = []
      root.roots = []
      root.endpoints = ({})
      root.history = []
      root.queue = []
      root.queueZoneId = ""
      root.volumeOverrides = ({})
      root.volumePending = ({})
      root.status = { state: "error", message: "Roon bridge exited (" + exitCode + ")" }
      restartTimer.restart()
    }
  }

  // Back off rather than hammer a core that is down or a venv that is broken.
  Timer {
    id: restartTimer
    interval: 5000
    repeat: false
    onTriggered: if (!bridge.running) mockCheck.running = true
  }

  IpcHandler {
    target: "roon"

    function status(): string {
      return JSON.stringify({
        state: root.status ? root.status.state : "unknown",
        message: root.statusLine,
        zone: root.activeZone ? root.activeZone.display_name : "",
        playing: root.activeZone ? root.activeZone.state === "playing" : false,
        title: root.activeZone ? root.activeZone.title : "",
        artist: root.activeZone ? root.activeZone.artist : "",
        album: root.activeZone ? root.activeZone.album : "",
        volume: root.activeZone ? root.volumePercentFor(root.activeZone) : -1,
        muted: Model.zoneMuted(root.activeZone),
        output: root.outputFormat(root.activeZone),
        outputDevice: root.outputDevice(root.activeZone)
      })
    }

    // Current browse level, for scripting and for seeing exactly what the
    // core sent when a row renders oddly.
    // Ask the bridge for the core's untouched payload, then read it back.
    function dumpRaw(what: string): string {
      root.rawDump = ""
      root.send({ cmd: what === "outputs" ? "raw_outputs"
        : (what === "queue" ? "raw_queue" : "raw_zones") })
      return "ok"
    }

    // Arbitrary browse call, untouched reply. optsJson is passed straight to
    // Roon, so this can reach hierarchies and fields the UI does not use.
    function rawBrowse(optsJson: string): string {
      var opts = {}
      try { opts = JSON.parse(optsJson || "{}") } catch (e) { return "bad json" }
      root.rawDump = ""
      root.send({ cmd: "raw_browse", opts: opts })
      return "ok"
    }

    function rawJson(): string {
      return root.rawDump
    }

    function browseJson(): string {
      return JSON.stringify(root.browse)
    }

    // Full zone state, for scripting and for working out why a zone looks
    // the way it does without attaching a second extension to the core.
    function search(text: string): string {
      return root.search(text, "") ? "ok" : "unhandled"
    }

    function queueJson(): string {
      return JSON.stringify({ zone: root.queueZoneId, items: root.queue })
    }

    function historyJson(): string {
      return JSON.stringify(root.history)
    }

    function endpointsJson(): string {
      return JSON.stringify(root.endpoints)
    }

    function zonesJson(): string {
      return JSON.stringify(root.zones)
    }

    function zones(): string {
      var names = []
      for (var i = 0; i < root.zones.length; i++) names.push(root.zones[i].display_name)
      return names.join("\n")
    }

    function playPause(): string { return root.playPause("") ? "ok" : "unhandled" }
    function next(): string { return root.next("") ? "ok" : "unhandled" }
    function previous(): string { return root.previous("") ? "ok" : "unhandled" }
    function volumeUp(): string { return root.stepVolume(5, "") ? "ok" : "unhandled" }
    function volumeDown(): string { return root.stepVolume(-5, "") ? "ok" : "unhandled" }
    function mute(): string { return root.toggleMute("") ? "ok" : "unhandled" }

    function selectZone(name: string): string {
      for (var i = 0; i < root.zones.length; i++) {
        if (root.zones[i].display_name === name) {
          root.selectZone(root.zones[i].zone_id)
          return "ok"
        }
      }
      return "unknown zone"
    }

    // `shell summon <id>` is owned by the overlay loader for any plugin that
    // declares an overlay kind, so the bar popup would otherwise have no
    // key-bindable entry point. Reach it through the bar host directly.
    function panel(): string {
      if (!root.shell || !root.shell.bar) return "unhandled"
      return root.shell.bar.summonBarWidget(root.pluginId) ? "ok" : "unhandled"
    }

    function panelClose(): string {
      if (!root.shell || !root.shell.bar) return "unhandled"
      return root.shell.bar.hideBarWidget(root.pluginId) ? "ok" : "unhandled"
    }

    function restart(): string {
      root.restart()
      return "ok"
    }

    function ping(): string { return "ok" }
  }
}
