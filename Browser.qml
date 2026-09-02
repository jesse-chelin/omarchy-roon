import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Ui
import qs.Commons
import "RoonModel.js" as Model

// Two-pane library browser: categories on the left, content on the right,
// the way the Roon app is laid out.
//
// Roon's browse API is a stack, not an addressable tree — the core holds one
// cursor for us and every step pushes onto it. A left nav is therefore not
// free: selecting a category unwinds that stack and re-descends (the bridge's
// browse_root), and the roots are cached from the top level rather than
// re-fetched.
//
// This file is now state and navigation. The rendering lives in NavPane and
// ContentPane; the two text boxes and their focus arbitration live in
// BrowserToolbar, because focus was the one part that kept breaking and it
// needed somewhere small enough to reason about.
Item {
  id: root

  property var shell: null
  property var service: null
  property var manifest: null

  property bool opened: false

  // Resolved when the browser opens, not bound live: a keyboard-summoned
  // overlay belongs on the output the user is looking at, but it should not
  // hop between monitors if focus moves while it is up.
  property var targetScreen: null

  property string focusPane: "content"
  property int navIndex: 0
  property int selectedIndex: 0
  property string selectedRootKey: ""
  property bool cursorActive: false
  property string filterText: ""
  property string pendingInputKey: ""
  property string pendingInputPrompt: ""
  property string toast: ""

  // The `?` reference. A layer over the browser rather than a level in it,
  // so it does not touch the navigation stack and never survives a close.
  property bool helpOpen: false

  // "" follows the per-level guess; "grid"/"list" is the user overriding it.
  property string viewOverride: ""

  // The term behind the results on screen, so the toolbar can say what you
  // are looking at and `s` can offer it back for refining.
  property string lastQuery: ""

  readonly property var browse: service ? service.browse : ({ items: [], crumbs: [], title: "" })
  readonly property string historyTitle: "Recently played"
  readonly property string queueTitle: "Queue"
  readonly property string favouritesTitle: "Favourites"

  // Roon's own categories, with our locally-kept history pinned above them.
  // It is not a Roon hierarchy and cannot be — the core exposes no history of
  // any kind — so it is synthesised here and labelled plainly in the toolbar.
  readonly property var roots: {
    var list = [
      { title: historyTitle, hint: "list", synthetic: true, mode: "history" },
      { title: favouritesTitle, hint: "list", synthetic: true, mode: "favourites" },
      { title: queueTitle, hint: "list", synthetic: true, mode: "queue" }
    ]
    var core = service ? service.roots : []
    for (var i = 0; i < core.length; i++) list.push(core[i])
    return list
  }

  readonly property bool historyMode: selectedRootKey === historyTitle
  readonly property bool queueMode: selectedRootKey === queueTitle
  readonly property bool favouritesMode: selectedRootKey === favouritesTitle
  readonly property bool syntheticMode: historyMode || queueMode || favouritesMode

  // Roon's root list does not include the rows we synthesised above it.
  readonly property int syntheticRootCount: {
    var n = 0
    for (var i = 0; i < roots.length; i++) if (roots[i].synthetic) n++
    return n
  }

  // What is actually coming next in the active zone. Roon's queue leads with
  // the track already playing, which is not a thing you can queue-jump to.
  readonly property var queueRows: {
    var out = []
    if (!service) return out
    var upcoming = Model.queueUpcoming(service.queue, zone ? zone.title : "")
    for (var i = 0; i < upcoming.length; i++) {
      var e = upcoming[i]
      var detail = []
      if (e.artist) detail.push(e.artist)
      if (e.album) detail.push(e.album)
      if (e.length) detail.push(Model.duration(e.length))
      out.push({
        title: e.title || "",
        subtitle: detail.join("  ·  "),
        item_key: "q" + i,
        hint: "action",
        art: e.art || "",
        catalog: false,
        queue_item_id: e.queue_item_id
      })
    }
    return out
  }

  // History rows are albums, matching Roon's own Recent Activity. They are not
  // browse items — we only ever saw the text on the now-playing screen — so
  // activating one asks the bridge to find that record and open it.
  readonly property var historyItems: {
    var out = []
    var entries = service ? service.history : []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      var detail = []
      if (e.artist) detail.push(e.artist)
      if (e.tracks > 1) detail.push(e.tracks + " tracks")
      if (e.zone) detail.push(e.zone)
      detail.push(Model.ago(e.at))
      out.push({
        title: e.album || e.title || "",
        subtitle: detail.join("  ·  "),
        item_key: "h" + i,
        hint: "action",
        art: e.art || "",
        catalog: false,
        album: e.album || e.title || "",
        artist: e.artist || ""
      })
    }
    return out
  }

  // Favourites are shaped exactly like history rows, so opening one goes
  // through the same album lookup and needs no second code path.
  readonly property var favouriteItems: {
    var out = []
    var entries = service ? service.favourites : []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      out.push({
        title: e.album || "",
        subtitle: e.artist || "",
        item_key: "f" + i,
        hint: "action",
        art: e.art || "",
        catalog: false,
        album: e.album || "",
        artist: e.artist || ""
      })
    }
    return out
  }

  readonly property var allItems: queueMode ? queueRows
    : (historyMode ? historyItems
    : (favouritesMode ? favouriteItems
    : (browse && browse.items ? browse.items : [])))
  readonly property var items: filterRows(allItems, filterText)
  readonly property bool inputMode: pendingInputKey !== ""
  readonly property var zone: service ? service.activeZone : null
  readonly property bool ready: service !== null && service.ready
  readonly property bool reduceMotion: service ? service.reduceMotion : false

  // An album or an artist: Roon gives the level its own cover, and only those
  // two have one. That is the whole test, and it is why the pane can be swapped
  // wholesale rather than threading conditionals through the ordinary one.
  readonly property bool detailMode: !syntheticMode && Model.isDetailLevel(browse)
  readonly property var detailAction: detailMode
    ? Model.detailBody(items).action : null

  readonly property bool isFavourite: service !== null && detailMode
    && service.isFavourite(browse.title, browse.subtitle, browse.art)

  // Roon's action menu is Play Now / Add Next / Queue / Start Radio. Walking
  // it is right when you want one of the other three and pure friction when
  // you want the first, which is nearly always.
  function playDefault() {
    if (!detailMode || !detailAction || !service) return
    service.playDefault(detailAction.item_key, browse.title, "")
    if (service.closeBrowserAfterAction) root.close()
  }

  function toggleFavourite() {
    if (!detailMode || !service) return
    service.toggleFavourite(browse.title, browse.subtitle, browse.art)
  }

  // Which kind of nothing an empty pane is showing.
  readonly property string emptyMode: queueMode ? "queue"
    : (historyMode ? "history"
    : (favouritesMode ? "favourites"
    : (searchResults || lastQuery !== "" ? "search"
    : (selectedRootKey ? "level" : ""))))

  // Where each initial letter starts, when the bridge could load the level
  // whole. Empty on a paged level — Tracks is ten thousand rows — and empty
  // while a filter is narrowing, because the indices would no longer point at
  // the rows on screen.
  readonly property var letters: (service && !syntheticMode && filterText === "")
    ? service.letters : []
  readonly property bool hasRail: letters.length > 2 && items.length > 40

  function jumpTo(index) {
    if (index < 0 || index >= items.length) return
    root.cursorActive = true
    root.focusPane = "content"
    root.disarmPointer()
    // The cursor travels with the view. Moving one without the other leaves
    // the keyboard behind wherever the eye used to be.
    root.selectedIndex = index
    if (contentPane) contentPane.jumpTo(index)
  }

  function jumpToLetter(letter) {
    if (!alphabetRail) return false
    return alphabetRail.jump(String(letter).toUpperCase())
  }

  property var alphabetRail: null

  readonly property var crumbs: browse && browse.crumbs ? browse.crumbs : []
  readonly property bool insideCategory: crumbs.length > 2

  readonly property bool searchResults: !syntheticMode && lastQuery !== ""
    && (browse.title || "").toLowerCase() === "search"

  // The synthetic history view is not a level in Roon's stack, so it has no
  // breadcrumb and must not inherit the last real one.
  readonly property string levelTitle: queueMode ? queueTitle
    : (historyMode ? historyTitle
    : (favouritesMode ? favouritesTitle
    : (searchResults ? "Search" : (browse.title || "Browse"))))
  readonly property string levelCount: queueMode
    ? (items.length === 0 ? "nothing queued"
       : items.length + (items.length === 1 ? " track" : " tracks") + " after this one")
    : (historyMode
    ? (items.length + (items.length === 1 ? " album" : " albums") + " · this plugin's own log")
    : (favouritesMode
    ? (items.length + (items.length === 1 ? " album" : " albums") + " · this plugin's own list")
    : (searchResults ? "“" + lastQuery + "”" : Model.levelCount(browse))))
  readonly property string trail: {
    if (syntheticMode) return ""
    var sep = "  " + Model.GLYPH.chevron + "  "
    // Origin is the door the user came through. When there is one, the core's
    // own route to the record is an implementation detail they never asked
    // about — Library > Search > Please describes our plumbing, not their trip.
    if (originKind !== "" && originReturnTo !== "")
      return originReturnTo + sep + levelTitle
    var trail = crumbs.slice(1)
    // One level in, the crumb is just the level's own name, which the gutter
    // is already showing. A breadcrumb of length one is not a trail.
    if (trail.length <= 1) return ""
    return trail.join(sep)
  }

  readonly property bool levelMixedSource: !syntheticMode && Model.levelIsMixed(items)

  // A level of tracks or actions carries no artwork, and a column of identical
  // placeholder squares is noise, not information. But a level of categories
  // carries no artwork either and its glyphs all differ — the nav rail beside
  // it has had icons since the first version, and the content pane showing
  // bare text next to it is why those rows read as an undifferentiated wall.
  readonly property bool levelHasArt: {
    for (var i = 0; i < allItems.length; i++) if (allItems[i].art) return true
    return Model.glyphsDiffer(allItems)
  }

  // A queue is about order, and every track on one record carries the same
  // cover, so the automatic grid turned it into a wall of identical squares.
  // Recently played stays automatic: those really are distinct albums.
  readonly property bool gridMode: viewOverride !== ""
    ? viewOverride === "grid"
    : (queueMode ? false : Model.prefersGrid(items))

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property string fontFamily: Style.font.menuFamily

  // One spacing scale for the whole surface, so the panes, rows and toolbar
  // line up instead of each carrying its own hand-picked number.
  readonly property int pad: Style.spacing.panelPadding
  readonly property int gap: Style.spacing.md
  readonly property int inset: Style.spacing.lg

  readonly property int navWidth: Style.space(190)
  readonly property int cardWidth: Math.min(Style.space(980), window.width - Style.gapsOut * 2)
  readonly property int rowHeight: Style.space(52)
  readonly property int artSize: rowHeight - Style.space(12)
  readonly property int navRowHeight: Math.max(Style.space(32), Style.font.body + Style.spacing.controlPaddingY * 2)
  readonly property int footerControlSize: Math.max(Style.space(26), Style.font.bodySmall + Style.spacing.controlPaddingY * 2)

  readonly property int scrollbarWidth: Math.max(2, Style.space(3)) + Style.space(4)
  readonly property int minTileWidth: Style.space(136)

  readonly property int maxCardHeight: Math.min(Style.space(680), window.height - Style.gapsOut * 2)

  readonly property int contentColumnWidth: cardWidth - pad * 2 - navWidth - gap * 2 - Math.max(1, Style.space(1))
  readonly property int gridUsableWidth: contentColumnWidth - scrollbarWidth
    - (hasRail ? Style.space(14) + gap : 0)

  // Divide the pane evenly rather than laying fixed-width tiles left to right
  // and leaving a ragged strip on the right.
  readonly property int gridColumns: Math.max(1, Math.floor(gridUsableWidth / minTileWidth))
  readonly property int tileWidth: Math.floor(gridUsableWidth / gridColumns)
  readonly property int tileGutter: Style.space(7)
  readonly property int tilePad: Style.space(6)
  readonly property int tileArt: tileWidth - tileGutter * 2 - tilePad * 2
  readonly property int tileHeight: tileArt + tilePad * 2 + tileGutter * 2
    + Style.font.bodySmall + Style.font.caption + Style.space(12)

  // Snap both views to whole rows so the pane never ends on a half-drawn row
  // or a beheaded album cover, which reads as a clipping bug rather than as
  // "there is more below".
  // No content-driven height any more: the card is fixed and the panes fill
  // it. A partially visible last row is the normal signal that a list
  // continues, and far less distracting than a window that resizes.

  function filterRows(rows, needle) {
    if (!needle) return rows
    var lower = needle.toLowerCase()
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if ((row.title + " " + row.subtitle).toLowerCase().indexOf(lower) !== -1) out.push(row)
    }
    return out
  }

  function resolveFocusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  // Reopening resumes where the user left off, like the Roon app; only a
  // browser that has never been opened starts from the top.
  function open(payloadJson) {
    root.targetScreen = root.resolveFocusedScreen()
    root.opened = true
    root.toast = ""
    root.helpOpen = false
    root.cancelInput()
    root.cursorActive = true
    // The service fetches these when it connects; this only covers a browser
    // opened before that happened. It no-ops once they are present, so the
    // two paths cannot both fire and emit the level twice.
    if (service) service.ensureRoots()
    root.restoreFocus()
  }

  function close() {
    root.opened = false
    root.helpOpen = false
    root.cancelInput()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // True once a category has been chosen for this connection. Without it the
  // auto-selector re-fires on every roots emission — and the bridge re-emits
  // roots as part of searching — so a search would be immediately replaced by
  // whatever category the selector picked.
  property bool rootAutoSelected: false

  // Set while a navigation the core has to think about is in flight. The
  // previous level stays on screen throughout — nothing flashes — so this is
  // the only signal that anything is happening.
  property bool busy: false

  // Where the content on screen came from.
  //
  // Roon's browse stack is not the user's history. Opening a remembered album
  // walks Library → Search → Album inside the core, so unwinding that stack
  // dropped the user into a search page they never asked for and never back
  // to Recently played. Origin records the door they actually came through,
  // and Back uses it once the stack is unwound to that depth.
  property string originKind: ""      // "history" | "search" | ""
  property string originReturnTo: ""  // nav row to return to
  property int originDepth: 0
  property bool originPending: false

  function beginNavigation(kind, returnTo) {
    root.busy = true
    busyTimeout.restart()
    if (kind !== undefined) {
      root.originKind = kind
      root.originReturnTo = returnTo === undefined ? "" : returnTo
      root.originPending = true
    }
  }

  function clearOrigin() {
    root.originKind = ""
    root.originReturnTo = ""
    root.originDepth = 0
    root.originPending = false
  }

  // True when Back should leave by the door we came in rather than unwinding
  // another level of Roon's stack.
  readonly property bool atOrigin: originKind !== "" && crumbs.length <= originDepth

  function returnToOrigin() {
    var target = root.originReturnTo
    root.clearOrigin()
    root.lastQuery = ""
    var index = navIndexForKey(target)
    if (index >= 0) root.selectRoot(index)
    else root.focusNav()
  }

  function ensureRootSelected() {
    if (!service || !roots || roots.length === 0) return
    if (rootAutoSelected || selectedRootKey) return
    // Open on Recently played. The old first screen was Roon's Library level:
    // six words of plain text in the top third of a fixed card, which is the
    // rail's job repeated in the content pane. This is a wall of covers, and
    // covers are how people recognise records.
    for (var i = 0; i < roots.length; i++) {
      if (roots[i].mode === "history") {
        root.rootAutoSelected = true
        root.selectRoot(i)
        return
      }
    }
    for (var j = 0; j < roots.length; j++) {
      if (!roots[j].synthetic) {
        root.rootAutoSelected = true
        root.selectRoot(j)
        return
      }
    }
  }

  function selectRoot(index) {
    if (!service || index < 0 || index >= roots.length) return
    var target = roots[index]
    root.navIndex = index
    root.selectedRootKey = target.title
    if (root.inputMode) root.cancelInput()
    root.resetContentState()
    root.restoreFocus()
    root.lastQuery = ""
    root.clearOrigin()
    if (target.synthetic) {
      if (target.mode === "queue") service.refreshQueue("")
      else if (target.mode === "favourites") service.refreshFavourites()
      else service.refreshHistory()
      root.selectedIndex = 0
      return
    }
    // Roon's index, not ours — the rows we synthesised above its list are not
    // part of it, and there is more than one of them now.
    root.beginNavigation("", "")
    service.browseRoot(target.title, index - root.syntheticRootCount, "")
  }

  function resetContentState() {
    root.filterText = ""
    if (toolbar) toolbar.setFilter("")
    root.selectedIndex = 0
    root.viewOverride = ""
  }

  function navIndexForKey(key) {
    for (var i = 0; i < roots.length; i++) if (roots[i].title === key) return i
    return -1
  }

  // Hover moves the cursor, which is right when the pointer moves and wrong
  // when the *list* moves under a pointer that did not. A wheel scroll drags
  // eight hundred covers past a stationary mouse, each one claiming the cursor
  // on the way; the cursor then drags the view back to itself, which fights
  // the wheel. That feedback loop is why the album grid never scrolled
  // smoothly. The gate only lets a hover through when the pointer really moved.
  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.focusPane = "content"
    root.selectedIndex = index
  }

  function selectNavFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.focusPane = "nav"
    root.navIndex = index
  }

  // Keyboard movement is the only thing that scrolls the view to the cursor.
  // The views no longer follow currentIndex on their own, precisely so that a
  // hover cannot move them.
  function revealCursor() {
    if (contentPane && contentPane.visible) contentPane.revealCursor()
    if (detailPane && detailPane.visible) detailPane.revealCursor()
  }

  function step(dx, dy) {
    root.cursorActive = true
    root.disarmPointer()
    if (focusPane === "nav") {
      if (dy !== 0 && roots.length > 0)
        root.navIndex = (root.navIndex + dy + roots.length) % roots.length
      return
    }
    if (items.length === 0) return
    // In a grid the cursor moves in two dimensions; in a list, only one.
    var delta = gridMode ? (dy * gridColumns + dx) : (dy !== 0 ? dy : 0)
    if (delta === 0) return
    var index = root.selectedIndex
    for (var guard = 0; guard < items.length; guard++) {
      index = (index + delta + items.length) % items.length
      if (Model.isSelectable(items[index])) break
      delta = delta > 0 ? 1 : -1
    }
    root.selectedIndex = index
    root.revealCursor()
  }

  function focusNav() {
    root.focusPane = "nav"
    root.cursorActive = true
    var index = navIndexForKey(root.selectedRootKey)
    if (index >= 0) root.navIndex = index
  }

  function focusContent() {
    root.focusPane = "content"
    root.cursorActive = true
  }

  function activate(index) {
    if (focusPane === "nav") {
      root.selectRoot(index === undefined ? root.navIndex : index)
      root.focusContent()
      return
    }

    var target = index === undefined ? root.selectedIndex : index
    if (target < 0 || target >= items.length) return
    var item = items[target]
    if (!Model.isSelectable(item)) return

    // A queued track does have a Roon handle, so this is a real jump rather
    // than a lookup: play from here.
    if (root.queueMode) {
      if (item.queue_item_id === undefined) return
      if (service) service.playFromQueue(item.queue_item_id, "")
      if (!service || service.closeBrowserAfterAction) root.close()
      return
    }

    // A remembered or favourited album has no Roon item_key, so the nearest
    // honest thing to "play this again" is to look it up.
    if (root.historyMode || root.favouritesMode) {
      if (!item.album) return
      var cameFrom = root.selectedRootKey
      root.selectedRootKey = ""
      root.navIndex = 0
      root.resetContentState()
      root.restoreFocus()
      // Not a search: the bridge finds the record and opens it. Landing on a
      // page of search categories is what made this feel random.
      root.lastQuery = ""
      // Came in through one of the plugin's own lists; Back belongs there,
      // not in the search stack the core walked to find the record.
      root.beginNavigation("history", cameFrom)
      if (service) service.findAlbum(item.album, item.artist, "")
      return
    }

    if (item.input_prompt) {
      root.pendingInputKey = item.item_key
      root.pendingInputPrompt = item.input_prompt.prompt || item.title
      if (toolbar) toolbar.focusSearch("")
      return
    }

    // A row Roon marks "action" is a leaf — Play Now, Add Next, Queue, Start
    // Radio. Picking one is the end of the errand, so dismiss rather than
    // dropping the user back on a menu they are done with. Closing before the
    // round trip keeps it feeling immediate; the command is already sent.
    var terminal = item.hint === "action"
      && (!service || service.closeBrowserAfterAction)

    // Clicking past an open search prompt abandons it; leaving it half-open
    // over a different level was how the keyboard ended up dead.
    if (root.inputMode) root.cancelInput()

    root.resetContentState()
    root.beginNavigation()
    if (service) service.browseItem(item.item_key, null, "")
    if (terminal) root.close()
    else root.restoreFocus()
  }

  // Opens a search box that is not tied to any row, so it works at any depth
  // and cannot carry a stale key.
  function openGlobalSearch() {
    root.pendingInputKey = "__global"
    root.pendingInputPrompt = "Search Roon"
    root.focusPane = "content"
    // Re-opening search offers the last term back, so refining a search does
    // not mean retyping it.
    if (toolbar) toolbar.focusSearch(root.lastQuery)
  }

  function submitInput(text) {
    if (!root.pendingInputKey) return
    var key = root.pendingInputKey
    root.cancelInput()
    root.resetContentState()
    root.focusPane = "content"
    root.cursorActive = true
    if (!service) return
    if (key === "__global") {
      // Capture the category *before* clearing it, or Back has nowhere to
      // return to and strands the user on the results.
      var searchedFrom = root.selectedRootKey || root.originReturnTo
      root.selectedRootKey = ""
      root.navIndex = 0
      root.lastQuery = text
      // Back from search results returns to the category you searched from.
      root.beginNavigation("search", searchedFrom)
      service.search(text, "")
    } else {
      service.browseItem(key, text, "")
    }
  }

  function cancelInput() {
    root.pendingInputKey = ""
    root.pendingInputPrompt = ""
    if (toolbar) {
      toolbar.clearSearchText()
      toolbar.releaseFocus()
    }
  }

  function restoreFocus() {
    if (toolbar) toolbar.releaseFocus()
  }

  // Back peels one thing at a time, in the order the user built it up:
  // the search prompt, then the filter, then a browse level, then the pane.
  function back() {
    if (root.inputMode) { root.cancelInput(); return }
    if (root.filterText) {
      root.resetContentState()
      return
    }
    if (root.syntheticMode) { root.focusNav(); return }
    // Leave by the door we came in, once the stack is back to that depth.
    if (root.atOrigin) { root.returnToOrigin(); return }
    if (root.focusPane === "content" && root.insideCategory) {
      root.selectedIndex = 0
      root.viewOverride = ""
      root.beginNavigation()
      if (service) service.browseBack()
      return
    }
    root.focusNav()
  }

  // Which room a keypress lands in is the most consequential state in a
  // multi-room product, and it had no keyboard control at all.
  function cycleZone() {
    if (!service) return
    var zones = service.zones || []
    if (zones.length < 2) return
    var current = service.activeZone ? service.activeZone.zone_id : ""
    var index = 0
    for (var i = 0; i < zones.length; i++) if (zones[i].zone_id === current) { index = i; break }
    var next = zones[(index + 1) % zones.length]
    service.selectZone(next.zone_id)
    root.toast = Model.GLYPH.speaker + "  " + next.display_name
    toastTimer.restart()
  }

  function toggleView() {
    root.viewOverride = root.gridMode ? "list" : "grid"
  }

  function onLevelChanged() {
    root.viewOverride = ""
    root.disarmPointer()
    root.selectedIndex = Math.max(0, Model.firstSelectableIndex(root.items, 0, 1))
    if (contentPane) contentPane.positionAtBeginning()
    if (detailPane) detailPane.positionAtBeginning()
  }

  // Roon pages long lists; pull the next page as the user reaches the end
  // rather than loading hundreds of rows and their artwork upfront.
  //
  // One request at a time: a view can report "at the end" several times while
  // a page is still in flight, and firing again mid-flight is how a level ends
  // up somewhere the user never scrolled to.
  property bool pageInFlight: false

  function loadMore(atEnd) {
    if (!atEnd || !service || syntheticMode || pageInFlight) return
    var loaded = browse.offset + allItems.length
    if (loaded >= browse.count) return
    root.pageInFlight = true
    service.browsePage(loaded)
  }

  property var toolbar: null
  property var contentPane: null
  property var detailPane: null

  Connections {
    target: root.service
    enabled: root.service !== null
    function onBrowseChanged() {
      // Was this level asked for, or did it just turn up? Paging, the
      // follow-up load that completes a short level, and the home level the
      // core sends whenever the roots are fetched all arrive unbidden.
      var requested = root.busy
      root.pageInFlight = false
      root.busy = false
      // More of the same level: keep the cursor and the scroll position
      // exactly where the user left them.
      if (root.browse && root.browse.appended) return
      if (root.originPending) {
        root.originDepth = root.crumbs.length
        root.originPending = false
      }
      // A level the user navigated to replaces one of the plugin's own views;
      // clearing the key rather than stamping the level's title over it keeps
      // the nav unhighlighted, which is correct — a search result is not a
      // category. A level that arrived on its own must not touch it: a page
      // still in flight from Tracks was landing after a click on Recently
      // played and dragging the browser straight back to Tracks.
      if (requested && root.syntheticMode) root.selectedRootKey = ""
      if (!requested && root.syntheticMode) return
      root.onLevelChanged()
    }
    function onRootsChanged() { root.ensureRootSelected() }
    // MPRIS Raise: a desktop client asking to see the player.
    function onRaiseRequested() { root.open("{}") }
    function onMessageReceived(text, isError) {
      if (!root.opened) return
      root.toast = text
      toastTimer.restart()
    }
  }

  // Never leave the indicator spinning if a reply is lost.
  Timer {
    id: busyTimeout
    interval: 12000
    onTriggered: root.busy = false
  }

  Timer {
    id: toastTimer
    interval: 3200
    onTriggered: root.toast = ""
  }

  PanelWindow {
    id: window
    visible: root.opened
    color: "transparent"
    screen: root.targetScreen
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omarchy-roon-browser"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      // A keystroke is either text or navigation, never both. The toolbar owns
      // the two boxes, so it is the authority on which.
      blocked: toolbarItem.editing

      onMoveRequested: function(dx, dy) {
        if (!root.ready || root.helpOpen) return
        // In a grid, horizontal means "next tile"; in a list it means
        // back/forward through the hierarchy.
        if (root.gridMode && root.focusPane === "content") {
          root.step(dx, dy)
          return
        }
        if (dy !== 0) root.step(0, dy)
        else if (dx < 0) root.back()
        else root.activate()
      }
      onActivateRequested: if (root.ready && !root.helpOpen) root.activate()
      // `x` on the history view clears it. The log is the plugin's own, so
      // deleting it belongs where you can see what you are deleting.
      onDeleteRequested: {
        if (!root.ready || root.helpOpen || !root.historyMode || !root.service) return
        root.service.clearHistory()
        root.toast = "Recently played cleared"
        toastTimer.restart()
      }
      onCloseRequested: {
        // `?` is a layer over the browser, not a place you can be, so escape
        // peels it off before it closes anything.
        if (root.helpOpen) { root.helpOpen = false; return }
        root.close()
      }
      onTabRequested: function(direction) {
        if (!root.ready || root.helpOpen) return
        if (root.focusPane === "nav") root.focusContent()
        else root.focusNav()
      }
      onTextKey: function(text) {
        if (!root.ready) return
        // The reference is modal by design: while it is up the only key that
        // means anything is the one that takes it down again.
        if (text === "?") {
          root.helpOpen = !root.helpOpen
        } else if (root.helpOpen) {
          root.helpOpen = false
        } else if (text === "f") {
          root.toggleFavourite()
        } else if (text === "p") {
          root.service.playPause("")
        } else if (text === "[") {
          root.service.previous("")
        } else if (text === "]") {
          root.service.next("")
        } else if (text === "m") {
          root.service.toggleMute("")
        } else if (text === "-" || text === "_") {
          root.service.stepVolume(-3, "")
        } else if (text === "=" || text === "+") {
          root.service.stepVolume(3, "")
        } else if (text === ",") {
          root.service.seek(-10, "", "relative")
        } else if (text === ".") {
          root.service.seek(10, "", "relative")
        } else if (text === "/") {
          root.focusContent()
          toolbarItem.focusFilter()
        } else if (text === "g") {
          root.focusNav()
        } else if (text === "s") {
          root.openGlobalSearch()
        } else if (text === "z") {
          root.cycleZone()
        } else if (text === "v") {
          root.toggleView()
        } else if (text >= "1" && text <= "9") {
          root.activate(parseInt(text, 10) - 1)
        }
      }

      Keys.onPressed: function(event) {
        if (keyCatcher.blocked || root.helpOpen) return
        // Alt, because every plain letter is already a verb here and an
        // alphabet rail that stole thirteen of them would be a bad trade.
        if ((event.modifiers & Qt.AltModifier) && event.text
            && /^[a-z0-9#]$/i.test(event.text)) {
          if (root.jumpToLetter(event.text === "0" ? "#" : event.text))
            event.accepted = true
          return
        }
        if (event.key === Qt.Key_Backspace) {
          root.back()
          event.accepted = true
        }
      }

BorderSurface {
        id: card
        anchors.centerIn: parent
        // Fixed. Sizing to content meant the card grew and shrank between a
        // six-row category and an eight-hundred-album grid, and everything in
        // it moved under the pointer. A stable frame is worth more than a
        // snug one.
        width: root.cardWidth
        height: root.maxCardHeight
        radius: Style.cornerRadius
        color: root.background
        borderSpec: root.borderSpec

        // -- chrome pinned to the top -------------------------------------
        Column {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: root.pad
          spacing: root.gap

          Item {
            width: parent.width
            height: titleRow.implicitHeight

            Row {
              id: titleRow
              spacing: root.gap
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Model.GLYPH.music
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Roon"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }
            }

            // The room used to be stated up here as well as in the footer, in a
            // different visual language, and neither was where you change it.
            // It has one home in this window now: beside the transport, where
            // pressing it cycles rooms.
          }

          PanelSeparator { foreground: root.foreground }

          // Spans the full width above both panes rather than sitting inside
          // the content column. That keeps the nav and content lists on one
          // baseline, and stops the content jumping when a breadcrumb appears.
          Item {
            width: parent.width
            height: root.ready ? toolbarItem.implicitHeight : 0
            visible: root.ready
            clip: true

            BrowserToolbar {
              id: toolbarItem
              width: parent.width

              foreground: root.foreground
              fontFamily: root.fontFamily
              navWidth: root.navWidth
              gap: root.gap

              levelTitle: root.levelTitle
              countText: root.levelCount
              detailMode: root.detailMode
              levelTotal: root.syntheticMode ? 0 : (root.browse.count || 0)
              trail: root.trail
              gridMode: root.gridMode
              rowCount: root.items.length

              searching: root.inputMode
              searchPrompt: root.pendingInputPrompt
              focusFallback: keyCatcher

              onViewToggleRequested: root.toggleView()
              onSearchSubmitted: function(text) { root.submitInput(text) }
              onSearchCancelled: root.cancelInput()
              onFilterChanged: function(text) {
                root.filterText = text
                root.selectedIndex = Math.max(0, Model.firstSelectableIndex(root.items, 0, 1))
              }
              onStepRequested: function(dy) { root.step(0, dy) }
              onActivateRequested: root.activate()

              Component.onCompleted: root.toolbar = toolbarItem
            }
          }

          Rectangle {
            width: parent.width
            height: Math.max(1, Style.space(2))
            radius: height / 2
            color: "transparent"
            visible: root.ready

            Rectangle {
              id: busyBar
              height: parent.height
              radius: parent.radius
              color: Color.accent
              opacity: root.busy ? 1 : 0
              width: root.busy ? parent.width * 0.35 : 0
              Behavior on opacity {
                enabled: !root.reduceMotion
                NumberAnimation { duration: 120 }
              }

              SequentialAnimation on x {
                running: root.busy && !root.reduceMotion
                loops: Animation.Infinite
                NumberAnimation { from: 0; to: busyBar.parent.width * 0.65; duration: 750; easing.type: Easing.InOutQuad }
                NumberAnimation { from: busyBar.parent.width * 0.65; to: 0; duration: 750; easing.type: Easing.InOutQuad }
              }
            }
          }
        }

        // -- chrome pinned to the bottom ----------------------------------
        Column {
          id: footerBlock
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: root.pad
          spacing: root.gap

          PanelSeparator { foreground: root.foreground }

          NowPlayingBar {
            width: parent.width
            browser: root
          }
        }

        // -- everything between them --------------------------------------
        //
        // The flexible middle: the two panes once connected, the setup guide
        // before that. Either way it absorbs the height the chrome does not
        // use, so the toolbar growing a search row shortens the lists rather
        // than resizing the window.
        Item {
          id: middle
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: root.pad
          anchors.top: header.bottom
          anchors.topMargin: root.gap
          anchors.bottom: footerBlock.top
          anchors.bottomMargin: root.gap

          SetupGuide {
            anchors.centerIn: parent
            visible: !root.ready
            status: root.service ? root.service.status : null
            foreground: root.foreground
            fontFamily: root.fontFamily
            reduceMotion: root.reduceMotion
            contentWidth: Math.min(Style.space(460), parent.width - root.pad * 2)
          }

          Row {
            anchors.fill: parent
            visible: root.ready
            spacing: root.gap

            NavPane {
              browser: root
              roots: root.roots
              width: root.navWidth
              height: parent.height
            }

            Rectangle {
              width: Math.max(1, Style.space(1))
              height: parent.height
              color: Style.normalBorderFor(root.foreground, Color.accent)
            }

            ContentPane {
              id: contentPaneItem
              browser: root
              items: root.items
              gridMode: root.gridMode
              width: root.contentColumnWidth - (root.hasRail ? railItem.width + root.gap : 0)
              height: parent.height
              visible: !root.detailMode
              Component.onCompleted: root.contentPane = contentPaneItem
            }

            AlphabetRail {
              id: railItem
              browser: root
              height: parent.height
              visible: root.hasRail && !root.detailMode
              Component.onCompleted: root.alphabetRail = railItem
            }

            // An album or an artist gets its own screen rather than a shared
            // renderer with a header bolted on. It reads the same cursor and
            // activates the same indices, so nothing about the keyboard
            // changes when the layout does.
            DetailPane {
              id: detailPaneItem
              browser: root
              items: root.items
              width: root.contentColumnWidth
              height: parent.height
              visible: root.detailMode
              Component.onCompleted: root.detailPane = detailPaneItem
            }
          }
        }

        // Covers the whole card, header and footer included: it is a layer
        // over the browser, not a pane inside it.
        KeyboardHelp {
          anchors.fill: parent
          visible: root.helpOpen
          foreground: root.foreground
          background: root.background
          fontFamily: root.fontFamily
          gridMode: root.gridMode
          reduceMotion: root.reduceMotion
          onDismissed: root.helpOpen = false
        }
      }
    }
  }

  // -- support seams -------------------------------------------------------
  //
  // Keyboard focus inside a layer-shell surface is impossible to reason about
  // from outside the process and trivial to read from inside, so the state is
  // exposed rather than guessed at. Reachable via
  // `omarchy-shell shell call io.github.jesse-chelin.roon <fn>`.

  function submitSearch(text) {
    if (!root.inputMode) return "no prompt open"
    root.submitInput(text)
    return "ok"
  }

  // Drives the cursor from outside the process. Keyboard focus inside a
  // layer-shell surface cannot be synthesised, so without this there is no way
  // to exercise navigation without a human at the keyboard.
  function activateIndex(text) {
    var n = parseInt(text, 10)
    if (isNaN(n)) return "want an index"
    root.focusContent()
    root.selectedIndex = n
    root.activate(n)
    return "ok"
  }

  function selectRootByName(text) {
    for (var i = 0; i < root.roots.length; i++) {
      if (root.roots[i].title === text) { root.selectRoot(i); return "ok" }
    }
    return "no such row"
  }

  function toggleHelp() {
    root.helpOpen = !root.helpOpen
    return root.helpOpen ? "open" : "closed"
  }

  function setFilter(text) {
    if (toolbar) toolbar.setFilter(text || "")
    return "ok"
  }

  function stateJson() {
    return JSON.stringify({
      opened: root.opened,
      selectedRootKey: root.selectedRootKey,
      historyMode: root.historyMode,
      queueMode: root.queueMode,
      historyCount: root.historyItems.length,
      rootCount: root.roots.length,
      focusPane: root.focusPane,
      inputMode: root.inputMode,
      helpOpen: root.helpOpen,
      letters: root.letters.length,
      hasRail: root.hasRail,
      letterSample: root.letters,
      prompt: root.pendingInputPrompt,
      filterText: root.filterText,
      selectedIndex: root.selectedIndex,
      itemCount: root.items.length,
      gridMode: root.gridMode,
      levelTitle: root.levelTitle,
      originKind: root.originKind,
      originDepth: root.originDepth,
      crumbDepth: root.crumbs.length,
      atOrigin: root.atOrigin,
      editing: toolbarItem.editing,
      keyCatcherBlocked: keyCatcher.blocked,
      keyCatcherFocus: keyCatcher.activeFocus
    })
  }

  IpcHandler {
    target: "roon-browser"

    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function show(): void { root.open("{}") }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }
}
