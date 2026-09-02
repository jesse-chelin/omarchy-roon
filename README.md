# Roon for Omarchy

Browse and control a [Roon](https://roon.app) core from the Omarchy desktop.

**What it is for:** Roon without leaving the keyboard. The phone app wins on
the sofa — better artwork, editorial content, Focus, all the things Roon's
extension API withholds. This wins at the desk, where reaching for a phone to
skip a track is the actual friction. Every feature here is measured against
the time from *"I want that record"* to it playing.

- **Media keys, `playerctl`, and Omarchy's own media widget** all drive Roon,
  because the plugin publishes the active zone on D-Bus as a standard MPRIS
  player. No configuration, no keybindings.
- **Bar widget** — now playing for the active zone, with a panel holding
  artwork, a seek bar, transport, volume, the queue, grouping, per-output
  trim and a zone switcher.
- **Library browser** — a fullscreen, keyboard-first browser laid out like the
  Roon app: categories left, content right, cover grid where it earns its
  place. Plus a Queue and a Recently played the core cannot give us.
- **Output format** — what the speaker is actually decoding, asked of the
  speaker, because Roon will not say.

## Install

```sh
omarchy plugin add https://github.com/jesse-chelin/omarchy-roon.git
omarchy plugin enable io.github.jesse-chelin.roon --section center
```

Then authorise it once: **Roon → Settings → Extensions → Enable "Omarchy"**.
The widget shows the pairing prompt until you do.

That is the whole install. The Python environment the bridge runs in is built
on first launch — the plugin tells you it is doing it — and the token is
written to `~/.local/state/omarchy-roon/session.json` (mode 0600).

### Keybindings

Media keys work already. These are optional, for the two surfaces:

```sh
omarchy-roon keybindings            # show them
omarchy-roon keybindings --install  # append to ~/.config/hypr/bindings.conf
```

`shell summon` is not the path: Omarchy hands `summon` to the overlay loader
for any plugin declaring an overlay kind, so `roon-browser` and `roon panel`
are the addressable targets.

## Settings

Per-widget settings live in the widget's entry in `~/.config/omarchy/shell.json`:

| Key             | Default | Meaning                                            |
|-----------------|---------|----------------------------------------------------|
| `core`          | `""`    | Core host or IP. Blank auto-discovers over SOOD.    |
| `maxLabelWidth` | `200`   | Width in px before the now-playing label scrolls.   |
| `showWhenIdle`  | `false` | Keep the widget in the bar when nothing is playing. |
| `closeBrowserAfterAction` | `true` | Dismiss the browser after Play Now / Add Next / Queue. Set `false` to stay on the action menu. |
| `showOutputFormat` | `true` | Ask the zone's endpoint what it is decoding. Involves LAN queries to third-party devices; set `false` to stay off the network. |
| `showProgress` | `true` | A hairline progress line under the bar label. |
| `showArtInBar` | `true` | Album art in place of the music glyph in the bar. |

```json
{ "id": "io.github.jesse-chelin.roon", "core": "192.168.1.20", "showWhenIdle": true }
```

Set `core` when auto-discovery fails — SOOD is multicast, so it does not
survive most VPNs, VLAN boundaries, or a bridged/NAT'd VM.

## Mouse and keys

**Bar widget**

| Input        | Action                       |
|--------------|------------------------------|
| Left click   | Open the now-playing panel   |
| Right click  | Play/pause the active zone   |
| Middle click | Next track                   |
| Scroll       | Volume on the active zone    |

**Browser** — two panes: categories left, content right.

| Key                 | Action                                              |
|---------------------|-----------------------------------------------------|
| `Tab`               | Switch between the category and content panes        |
| `j` / `k`, ↑ / ↓    | Move the cursor in the focused pane                  |
| ← / →               | Move between covers in grid view                      |
| `Enter`, `Space`, → | Open the row, or run the action                      |
| `Backspace`, `h`, ← | Up one level; at a category's top, back to the panes |
| `/`                 | Filter the rows already on screen                     |
| `v`                 | Switch between cover grid and list for this level     |
| `s`                 | Search Roon from any depth (offers the last term back) |
| `g`                 | Jump to the category pane                            |
| `1`–`9`             | Activate that row in the focused pane                |
| `Esc`               | Close (clears the search/filter first)               |

Picking a leaf action — Play Now, Add Next, Queue, Start Radio — dismisses the
browser, since that is the end of the errand. Set `closeBrowserAfterAction` to
`false` to stay on the action menu instead.

Selecting a category is always two keystrokes from anywhere, however deep you
have gone — the category pane is a fixed landmark rather than another level to
back out of. The filter box narrows the rows already on screen; rows Roon marks
as search prompts open a second box whose text goes to the core instead.

Reopening the browser resumes where you left off, as the Roon app does.

## CLI

```sh
omarchy-roon status          # active zone as JSON
omarchy-roon zones           # zone names
omarchy-roon zones-json      # full zone state, for scripting
omarchy-roon play-pause
omarchy-roon next | previous
omarchy-roon volume-up | volume-down | mute
omarchy-roon zone "Kitchen"  # pick the zone the widget controls
omarchy-roon panel           # open the now-playing panel
omarchy-roon search "term"   # search library + streaming catalogue
omarchy-roon history         # recently played, as JSON
omarchy-roon browse          # open the library browser
omarchy-roon restart         # restart the bridge process
```

## How it works

Omarchy's shell ships no `QtWebSockets` QML module, and Roon speaks its own
framed protocol over a WebSocket, so QML cannot talk to a core directly.

```
omarchy-shell (Quickshell)                    bridge/roon_bridge.py
┌───────────────────────────┐   NDJSON over  ┌──────────────────────┐
│ Service.qml   (state)     │◄──── stdio ───►│ roonapi (pyroon)     │◄──► Roon core
│ BarWidget.qml (bar+popup) │                │ discovery, auth,     │
│ Browser.qml   (overlay)   │                │ zones, browse        │
└───────────────────────────┘                └──────────────────────┘
```

`Service.qml` owns exactly one bridge process per shell — never one per bar or
per monitor — so the auth token, zone state and browse position stay coherent
across every surface. Commands go down as one JSON object per line; zone
snapshots, browse levels and status come back the same way and are pushed, not
polled. The bridge restarts with a 5s backoff if it dies.

Album art is a plain HTTP URL on the core, so QML `Image` loads it directly
without the art ever passing through the bridge.

Three details are shaped by Roon's API rather than by preference:

- **Display strings carry markup.** Roon embeds entity links as
  `[[1657722|Erykah Badu]]`, which its own app renders as tappable links.
  We navigate by item_key, not by those ids, so the bridge keeps the label and
  drops the id — otherwise a Qobuz subtitle reads as a wall of raw numbers.

- **The category pane costs something.** Roon's browse hierarchy is a stack the
  core holds open for us, not a tree with addressable nodes. Selecting a
  category therefore unwinds that stack and re-descends (`browse_root` in the
  bridge), and the category list itself is cached from the top level rather
  than re-fetched on every navigation.
- **Volume is optimistic.** A slider drag emits a value per mouse move, and
  each one is a round trip to the core. The service shows the requested value
  immediately and sends at most one command per 90ms tick, always the newest,
  dropping the local value once the core confirms it (or after 2s if it never
  does). Without this the knob fights the stale value coming back and feels
  like it is lagging.

The bridge runs from its own virtualenv under
`$XDG_STATE_HOME/omarchy-roon/venv` rather than system Python, because Arch
marks its interpreter externally-managed and the shell should not depend on
whatever happens to be on `PATH`. Re-run `install.sh` after a Python major
version bump.

## Development

Run every check that does not need a Roon core:

```sh
./check.sh
```

That is the manifest schema check, `qmllint` against the shell's imports, the
QML unit tests, and a syntax pass over the bridge — one entry point, suitable
for CI.

### Layout

| File | Responsibility |
|------|----------------|
| `Service.qml` | The one bridge process, all shared state, the IPC surface |
| `Browser.qml` | Browser state and navigation; no rendering |
| `BrowserToolbar.qml` | The level heading, breadcrumb, view toggle, and **both** text boxes |
| `FocusArbiter.qml` | Who owns keyboard focus. ~40 lines, unit-tested |
| `NavPane.qml` / `ContentPane.qml` | Renderers over the browser's state |
| `BarWidget.qml` | Bar item and now-playing panel |
| `SetupGuide.qml` | Onboarding, shared by the panel and the browser |

Both text boxes live in one component because they compete for focus, and that
competition caused three separate bugs — a filter that ignored typing, an
overlay that stopped responding to keys, and search results that vanished.
`FocusArbiter` states the rule once (*the last stated intention wins, evaluated
when the event loop settles*) and `tests/tst_focusarbiter.qml` pins it down.
Those tests run offscreen in milliseconds with no shell and no core.

`NavPane` and `ContentPane` take a `browser` back-pointer rather than a long
property list. They are renderers, not independent components; the parts worth
isolating were focus and the toolbar, and those have real interfaces.


Working on the UI without a Roon core on the network:

```sh
touch ~/.local/state/omarchy-roon/mock   # bridge serves fabricated zones + library
omarchy-restart-shell
rm ~/.local/state/omarchy-roon/mock      # back to a real core
```

Writing a state name into that file pins the connection status, which is the
only practical way to review the setup screens once the extension is approved:

```sh
echo waiting     > ~/.local/state/omarchy-roon/mock   # the Roon approval screen
echo nocore      > ~/.local/state/omarchy-roon/mock   # the "no core found" screen
echo discovering > ~/.local/state/omarchy-roon/mock
```

The bridge also runs standalone, which is the fastest way to see the wire
protocol:

```sh
echo '{"id":1,"cmd":"browse_home"}' \
  | ~/.local/state/omarchy-roon/venv/bin/python bridge/roon_bridge.py --mock
```

Validating before publishing:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/io.github.jesse-chelin.roon
qmllint -I "$OMARCHY_PATH/shell" Service.qml BarWidget.qml Browser.qml
```

QML edits are only picked up by a full `omarchy-restart-shell`. The overlay is
`keepLoaded`, so `omarchy-shell shell rescanPlugins` will not re-read it.

## Troubleshooting

**`roonapisocket -- Connection is not (yet) ready!` in the shell log at
startup.** Harmless. pyroon fetches the first zone snapshot inside its
constructor, before the websocket has finished registering, so that request
fails. The bridge re-fetches the snapshot once the socket is actually ready —
without that, a zone whose first message happened to be a partial seek update
would show up with no name and no outputs.

**A zone is missing or unnamed.** `omarchy-roon zones-json` shows exactly what
the core reported. Zones appear only when their endpoint is awake.

**"No Roon core found."** SOOD discovery is multicast and does not cross VPNs,
VLANs, or a NAT'd VM. Set `core` in the widget settings to the core's address.
The bridge retries on its own with a backoff up to five minutes, so a core that
boots later is picked up without restarting the shell.

## Playback

The panel is the transport surface, and covers a zone as Roon models one:

- **Queue** — the bridge subscribes to the transport service's queue endpoint
  per zone. The browser has a **Queue** category showing what follows, in
  order, with durations; selecting a track jumps to it. The panel carries the
  next track and a count. Roon's queue leads with the track already playing,
  which is dropped — "up next" that shows what is on is not up next.
- **Grouping** — every other room carries a link button that adds its output to
  the current zone. Whether two endpoints *can* play in sync is Roon's call,
  read from `can_group_with_output_ids`, so the button disables itself with a
  reason rather than failing after the press.
- **Move playback** — an arrow on each other room hands it the queue and the
  position.
- **Per-output volume** — a zone with more than one output grows an outputs
  section with a slider each, so rooms can be trimmed against each other.
- **Standby** — outputs advertising `supports_standby` get a sleep button.

Two caveats worth knowing. Roon only groups like with like, so a WiiM will not
join a Sonos — if every button is disabled, that is Roon's answer, not a bug.
And the grouping and per-output paths have only been exercised against the mock:
this system has three zones of one output each and no groupable pairs.

## Recently played

Roon exposes **no** play history and **no** "recently added". Established by
probing, not assumption:

- Every alternate browse hierarchy — `home`, `recent`, `history`, `library`,
  `overview`, `recently_added`, `now_playing`, `queue`, `discover` — returns
  `InvalidHierarchy`. The valid set is `browse`, `albums`, `artists`,
  `playlists`, `genres`, `composers`, `internet_radio`, `search`, `settings`.
- `Settings → Display Settings` offers only *Show Hidden Items*,
  *Artists Sort By* and *Composers Sort By*.
- The `albums` hierarchy is alphabetical, and passing `sort: "date_added"`
  returns byte-identical output — the option is silently ignored.

So the bridge keeps its own log. It already observes every track change in
every zone, and writes them to
`$XDG_STATE_HOME/omarchy-roon/history.json` (capped at 300).

**Grouped by album**, as Roon's own Recent Activity is: forty tracks off one
record is one thing you listened to, not forty. Each row shows the album, its
artist, how many of its tracks have played, the zone, and how long ago.

Identity is the **cover**, not album-plus-artist. Roon reports the *track*
artist, so a guest feature changes it mid-record and the same album would fork
into several rows. One `image_key` per album makes the artwork a reliable
discriminator, and two different albums sharing a title still get their own
entry. Artist is the fallback where there is no artwork; a radio stream with
no album falls back to its track title.

A remembered album has no Roon `item_key` — we only ever saw the text on the
now-playing screen — so selecting one asks the bridge to find that record and
**open it**, landing on Play Album and the track list.

Finding it searches by album title alone. Including Roon's artist string made
matches worse, not better: it is the *track* artist, so on a record with guests
it runs to five names and drags in unrelated hits. The artist is used only to
break ties when several records share a title. Some results wrap an album in a
container of the same name, which the bridge steps through so you land on the
record rather than a page containing it. If nothing matches exactly, the album
results stay on screen with a note — closer than a page of search categories,
which is what made this feel random before.

**Recently added has no equivalent** and never will from this API: it is
library metadata the browse service does not carry, and unlike play history
there is nothing to observe.

## Library or streaming

Browse items carry exactly `title`, `subtitle`, `image_key`, `item_key` and
`hint` — no provenance field, and no distinguishing action when you drill in
(checked against both a library album and a Qobuz-only one; both offer
Play Now / Add Next / Queue / Start Radio).

There is one usable signal. Roon writes catalogue artists as entity links —
`[[14671454|Atrice]]` — and library artists as plain text. That holds across
every level checked: the local Albums list is entirely plain, a Qobuz browse
entirely marked up, and a search result mixes the two exactly along the
library boundary. The bridge records it as `catalog` before stripping the
markup.

It is an inference, so it is used conservatively: the badge appears **only in
lists that contain both kinds**, where the distinction is informative, and
never in a list that is uniformly one or the other. A disk glyph in the accent
colour means the item is in your library; a cloud glyph means it comes from the
streaming catalogue.

## Search

Roon's search is global — results already include the streaming catalogue, so
there is nothing separate to configure for Qobuz. Searching *Backrooms* on this
core returns the two library albums first and 35 Qobuz matches behind them.

**Qobuz has no search of its own.** Its browse subtree is New Releases,
Playlists, Taste of Qobuz and My Qobuz, none of which takes input. That is
Roon's hierarchy, not a gap in this plugin — use `s` and search globally.

Searching goes through a dedicated bridge command that walks down to the search
row from a fresh root every time, rather than reusing an `item_key` captured
when the row was drawn. Roon regenerates those keys whenever the browse stack
moves, and a stale one returns `InvalidItemKey` — which is how a search that
works perfectly at the protocol level can return nothing in a UI.

### Search is not the filter

They are different things and the UI keeps them apart. **Search** (`s`) queries
the core and replaces the level; it appears as its own accent-framed row, and
the toolbar then shows the term you searched for. **Filter** (`/`) narrows the
rows already on screen and never touches the core; its placeholder counts them
(*Filter these 37 rows…*), and it greys out while a search box is open.

Both are text boxes in the same region, so focus is arbitrated explicitly: a
deliberate claim on one always beats a pending restore aimed at the cursor.
Without that, keystrokes intended for a box landed on the list as navigation —
which looks exactly like the filter not working.

## Back returns where you came from

Roon's browse stack is not the user's history, and treating it as one made
navigation feel broken. Opening a remembered album walks
`Library → Search → Album` *inside the core*, so unwinding that stack dropped
you into a search page you never asked for — and never back to Recently played.

Each navigation therefore records the door it came through: the category you
picked, the search you ran, or the history row you clicked, along with the
stack depth its result landed at. Back unwinds Roon's levels while you are
deeper than that, and leaves by the recorded door once you reach it.

| From | Back goes to |
|------|--------------|
| Recently played → album → its actions | album, then Recently played |
| A category → a search → a hit | the results, then that category |
| Library → Albums → an album | Albums, then Library, then the category pane |

Back also peels one thing at a time in the order you built it up: an open
search box first, then the filter, then a browse level, then the pane.

## The browser is a fixed frame

The card is one size, always. It used to grow and shrink to fit its contents,
which meant a six-row category and an eight-hundred-album grid produced very
different windows and everything moved under the pointer between them. Now the
chrome is pinned top and bottom and the panes absorb whatever is left — so a
search box opening shortens the lists rather than resizing the window, and a
partially visible last row does what it does everywhere else: signals that the
list continues.

## Navigation is single-step

Anything the plugin does in several browse calls emits **one** level to the UI,
never the ones it passed through. Opening a remembered album searches, matches
the record, descends into it, and sometimes steps through a container of the
same name — four calls, one screen. Emitting the intermediates is what made it
flash another view on the way.

Long levels append rather than replace. Roon serves a level a page at a time,
and treating each page as a fresh level meant opening Albums could jump from
*8 Miles High* to *Black Star* on its own — the grid reported "at the end"
during first layout, fetched page two, and swapped it in. Pages are now merged
onto the level they belong to, the cursor and scroll position survive, one
request is in flight at a time, and a view that is not scrollable never asks
for more.

## Output format

Roon's extension API carries **no** format information. Verified by dumping the
untouched payloads from a live core:

```
now_playing:  seek_position, length, one_line, two_line,
              three_line, image_key, artist_image_keys
queue item:   queue_item_id, length, image_key, + the same three lines
```

No codec, sample rate, bit depth, channel count or signal path anywhere. The
`FLAC 44.1kHz 16bit 2ch` readout in the Roon app comes from the core's internal
media database, which is first-party only.

So the plugin asks the **speakers** instead. `bridge/endpoints.py` discovers
renderers over SSDP, pairs each Roon zone with a device by name, and asks it
what it is decoding. The panel shows the result under the zone name, prefixed
`OUT`.

| Family | How it is asked | What comes back |
|--------|-----------------|-----------------|
| **BluOS** — Bluesound, NAD | `http://<ip>:11000/Status` | `streamFormat`, already formatted (`FLAC 44100/16/2`). The richest of any endpoint. |
| **LinkPlay** — WiiM, Arylic, Audio Pro, Dayton | `https://<ip>/httpapi.asp?command=getMetaInfo` | Sample rate and bit depth. HTTPS with a self-signed cert on newer firmware, so verification is skipped — LAN only, against a device just discovered. |
| **Sonos** | UPnP `AVTransport.GetPositionInfo` | Codec, from the DIDL `protocolInfo`. Roon transcodes to Sonos, so this is Roon's transport encoding. |
| **Generic UPnP/DLNA** — Lumin, Auralic, Cambridge, Yamaha MusicCast, Denon/Marantz HEOS | same DIDL `res` element | `sampleFrequency`, `bitsPerSample`, `nrAudioChannels` when the renderer populates them; codec otherwise. |

**It is labelled `OUT` for a reason.** This is what the speaker is receiving,
not the source file. For a RAAT endpoint Roon sends bit-perfect, so the two
match. For something Roon transcodes to — Sonos, AirPlay — they do not.

Probing is driven by track changes, not a poll loop, and runs on its own thread
so a slow or absent speaker never delays a transport command. Zones that are
stopped are skipped; paused ones still have a track loaded and are read.

### When a zone does not match

Roon gives us a zone's display name and nothing else — no address, no shared
identifier — so pairing is name matching, and that is the weak link. Sonos
exposes `roomName` (`Media Room` pairs with the zone `Media Room - Sonos`), and
LinkPlay exposes a friendly name (`WiiM Ultra-114A` pairs with `WIIM`). For
anything that lands wrong or is invisible to SSDP, pin it by hand in
`~/.config/omarchy-roon/endpoints.json`:

```json
{ "Bedroom speaker": "172.16.11.31" }
```

Run the prober standalone to see what your network yields:

```sh
cd bridge
python3 endpoints.py discover
python3 endpoints.py probe
python3 endpoints.py match "Media Room - Sonos"
```

## What Roon still does not expose

- **Signal path.** The chain of DSP stages Roon shows is not in any service.
- **Lyrics, biographies, reviews and credits.**
- **Focus filtering and bookmarks.**
- **Playlist editing.** Playlists can be browsed and played, not modified.

## When something breaks

Three risks are concentrated and worth naming, because a marketplace listing
should say whether a bad update means a dead plugin or a degraded one.

| If this breaks | You lose | You keep |
|----------------|----------|----------|
| **jeepney** (MPRIS) | Media keys, `playerctl`, the Omarchy media widget | Everything else; the bridge logs why and carries on |
| **The endpoint probes** (WiiM, Sonos, BluOS, UPnP) | The `OUT` format readout for that zone | Everything else; a probe that throws is skipped |
| **pyroon** | The plugin | — it is the connection. This is why both it and websocket-client are pinned exactly |

pyroon is the one that cannot degrade, so it is guarded rather than hoped
about: the bridge calls two of its private methods (`_get_zones`,
`_get_outputs`) to work around it seeding state before the socket registers,
and checks they exist at connect time. If an upgrade removes them you get a
sentence saying so, not zones that silently never appear.

The library-versus-streaming badge is an inference from undocumented markup.
If Roon changes it, the badge stops appearing — it never points at the wrong
thing, because it only shows in lists containing both kinds.

## Security

The plugin runs unsandboxed inside `omarchy-shell`, like every Omarchy plugin.
It talks only to the Roon core, over the LAN, on the port the core advertises.
The extension token in `session.json` grants control of your zones — treat it
as a credential.

## License

MIT — see [LICENSE](LICENSE).
