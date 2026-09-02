#!/usr/bin/env python3
"""NDJSON stdio bridge between omarchy-shell and a Roon core.

The shell has no WebSocket QML module, so QML cannot speak Roon's MOO
protocol itself. This process owns the Roon connection and speaks a flat,
line-delimited JSON dialect over stdio instead:

    stdin   one command object per line
    stdout  one event object per line
    stderr  human-readable log

Every command may carry an "id"; the matching "result" or "error" event
echoes it back. State events ("status", "zones", "browse") are pushed
unsolicited whenever the core changes, so the UI never polls.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import re
import sys
import unicodedata
import threading
import time

from roonapi.constants import SERVICE_TRANSPORT

import endpoints as endpoint_probes

# Optional, and it says so. MPRIS is the best thing this plugin does, but it
# is not the thing it is for — a missing or broken jeepney must cost you the
# media keys, not the plugin. Same reasoning for the endpoint prober, which
# needs nothing but stdlib and so cannot fail this way.
try:
    from mpris import MprisService
except Exception as _mpris_import_error:  # noqa: BLE001
    MprisService = None
    _MPRIS_UNAVAILABLE = repr(_mpris_import_error)
else:
    _MPRIS_UNAVAILABLE = ""

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "omarchy-roon",
)
SESSION_FILE = os.path.join(STATE_DIR, "session.json")
HISTORY_FILE = os.path.join(STATE_DIR, "history.json")
HISTORY_LIMIT = 300
FAVOURITES_FILE = os.path.join(STATE_DIR, "favourites.json")
FAVOURITES_LIMIT = 500

APPINFO = {
    "extension_id": "org.omarchy.roon",
    "display_name": "Omarchy",
    "display_version": "0.1.0",
    "publisher": "Omarchy Roon plugin",
    "email": "none@example.com",
}

# Roon embeds entity links in display strings as [[id|Display Name]] — the
# Roon app renders those as tappable artist/album links. We navigate by
# item_key, not by these ids, so the id is dropped and the label kept;
# otherwise a Qobuz subtitle reads "[[1657722|Erykah Badu]] & [[3117946|...".
ROON_LINK = re.compile(r"\[\[(?:([^|\]]*)\|)?([^\]]*)\]\]")


def has_link_markup(*values) -> bool:
    """True when Roon rendered any of these as catalogue entity links.

    An inference, and the only one available: browse items carry nothing but
    title, subtitle, image_key, item_key and hint. Across every level checked
    against a live core — the local Albums list, a Qobuz browse, and a mixed
    search result — rows drawn from the streaming catalogue have their artist
    written as [[id|Name]] while rows already in the library have plain text.
    Used only to mark rows in a list that contains both kinds, so a wrong
    guess costs a badge rather than a wrong destination.
    """
    return any("[[" in str(v or "") for v in values)


def _initial(title):
    """The rail bucket a title belongs in: A-Z, or # for everything else.

    Accents are folded rather than given buckets of their own — a rail with
    separate stops for A, Á and Æ is not an alphabet, and the three records
    behind them would each be unreachable from the twenty-six letters anyone
    actually looks for. Anything that is not a Latin letter after folding —
    numerals, symbols, and the one artist in this library whose name is a
    zalgo emoticon — sorts under #.
    """
    folded = unicodedata.normalize("NFKD", clean_text(title))
    for char in folded:
        if unicodedata.combining(char):
            continue
        if "a" <= char.lower() <= "z":
            return char.upper()
        if char.isspace():
            continue
        # NFKD splits an accent off its letter but leaves a ligature whole, so
        # Æ and Ø arrive here intact. Unicode names them for us:
        # "LATIN CAPITAL LETTER AE" is filed under A, which is where anyone
        # reaching for that record would look.
        letter = _latin_name_letter(char)
        return letter if letter else "#"
    return "#"


_LATIN_LETTER = re.compile(r"^LATIN (?:CAPITAL|SMALL) (?:LETTER|LIGATURE) ([A-Z])")

# Latin-1 Supplement through Latin Extended-B, and no further. Past U+0250 are
# the IPA extensions, where "LATIN SMALL LETTER SQUAT REVERSED ESH" would file
# a zalgo artist name under S on the strength of the word "SQUAT".
_LATIN_ALPHABET_END = 0x0250


def _latin_name_letter(char):
    """The letter a Latin ligature or stroked form belongs with, or ""."""
    if ord(char) >= _LATIN_ALPHABET_END:
        return ""
    try:
        name = unicodedata.name(char)
    except ValueError:
        return ""
    match = _LATIN_LETTER.match(name)
    return match.group(1) if match else ""


def letter_marks(titles, run=4):
    """Where each initial letter starts, read as runs rather than as points.

    Roon returns the level sorted by Roon's collation, not ours: it ignores
    leading articles and punctuation, so a handful of rows sit nowhere near
    where their first character says they should. Every point-wise reading of
    that fails, and all three failed here against the real 788-album library:

      * first occurrence per letter — one row at index 11 took T and sent the
        rail to the top of the list;
      * first occurrence, forced to climb — that guard then locked out every
        letter below T, leaving eight stops of twenty-seven;
      * bisection — a stray sorted among the A's reads as "at or after B" and
        swallows the probe, which quietly dropped B, G, L, P and S.

    A letter starts where several consecutive rows sort at or after it. An
    isolated row cannot make a run, so it cannot claim a stop. The comparison
    is "at or after" rather than "equal" so that a letter with only two rows
    is still found, its run completed by the letters after it.
    """
    keys = [_initial(title) for title in titles]
    total = len(keys)
    if total == 0:
        return []

    # "#" is the top-of-level bucket, not a letter: it means the numerals Roon
    # sorts first. A "#" row further down is an unsortable title, not a second
    # stop, so this is taken from the head of the level or not at all.
    marks = []
    if keys[0] == "#":
        marks.append({"letter": "#", "index": 0})

    start = 0
    for letter in ALPHABET[1:]:
        index = -1
        for position in range(start, total):
            if keys[position] != letter:
                continue
            # A row of the right letter is a candidate, not a stop. Confirm it
            # by looking at what follows: a real letter is followed by rows
            # that keep sorting at or after it, and a stray is followed by the
            # letters it interrupted. Rows we cannot order are stepped over —
            # they are neither evidence nor counter-evidence.
            seen = 0
            confirmed = False
            for ahead in range(position, total):
                key = keys[ahead]
                if key == "#":
                    continue
                if key < letter:
                    break
                seen += 1
                if seen >= run:
                    confirmed = True
                    break
            else:
                # Ran to the end of the level: the run is as long as it can be,
                # which is what the last letters of the alphabet get.
                confirmed = seen > 0
            if confirmed:
                index = position
                break
        if index < 0:
            continue
        marks.append({"letter": letter, "index": index})
        start = index
    return marks


def clean_text(value):
    """Strip Roon's [[id|label]] link markup down to the label."""
    if not value:
        return ""
    text = ROON_LINK.sub(lambda m: m.group(2), str(value))
    # Leftover empty brackets from malformed markup would look like debris.
    return text.replace("[[", "").replace("]]", "").strip()


# Roon's browse hierarchy pages; 100 is what the official clients use.
PAGE_SIZE = 100

# A level at or under this many rows is pulled in full, in one extra request,
# straight after the first page. Below it the browser holds the whole level:
# scrolling never waits, the filter sees every row, and an A-Z rail can be
# exact because the titles are all here to index. Above it — Tracks is 10,682
# rows in this library — that would be megabytes for a list nobody scrolls
# end to end, so those stay paged and get no rail.
FULL_LOAD_LIMIT = 4000

# "#" sorts before "A" in ASCII, which is also where Roon puts the numerals.
ALPHABET = "#ABCDEFGHIJKLMNOPQRSTUVWXYZ"
ART_SIZE = 400


# --------------------------------------------------------------- transport

_out_lock = threading.Lock()


def emit(obj: dict) -> None:
    """Write one event line. Safe to call from any thread."""
    line = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    with _out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def log(*parts) -> None:
    print(*parts, file=sys.stderr, flush=True)


# ------------------------------------------------------------ session file


def load_session() -> dict:
    try:
        with open(SESSION_FILE, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_session(session: dict) -> None:
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = SESSION_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(session, handle, indent=2)
        handle.write("\n")
    # The token is a credential for the core; keep it to the owning user.
    os.chmod(tmp, 0o600)
    os.replace(tmp, SESSION_FILE)


# ----------------------------------------------------------- serialization


def _volume(output: dict) -> dict | None:
    """Flatten Roon's volume block, adding a 0-100 percent QML can bind to."""
    vol = output.get("volume")
    if not vol:
        return None
    low = vol.get("min", 0)
    high = vol.get("max", 100)
    value = vol.get("value", low)
    span = high - low
    percent = 0 if span <= 0 else round((value - low) / span * 100)
    return {
        "type": vol.get("type", "number"),
        "min": low,
        "max": high,
        "step": vol.get("step", 1),
        "value": value,
        "percent": max(0, min(100, percent)),
        "is_muted": bool(vol.get("is_muted", False)),
        "hard_limit_min": vol.get("hard_limit_min", low),
        "hard_limit_max": vol.get("hard_limit_max", high),
    }


class ZoneSerializer:
    """Turns Roon zone dicts into the flat shape the QML side binds to."""

    def __init__(self, image_url):
        self._image_url = image_url

    def zone(self, zone: dict) -> dict:
        now = zone.get("now_playing") or {}
        lines = now.get("three_line") or now.get("two_line") or now.get("one_line") or {}
        image_key = now.get("image_key")
        outputs = [self.output(o) for o in zone.get("outputs") or []]
        settings = zone.get("settings") or {}
        # A zone seen only through a partial update has no name of its own;
        # borrow its outputs' names rather than render a blank row.
        name = clean_text(zone.get("display_name")) or ", ".join(
            o["display_name"] for o in outputs if o.get("display_name")) or "Zone"
        return {
            "zone_id": zone.get("zone_id", ""),
            "display_name": name,
            "state": zone.get("state", "stopped"),
            "is_play_allowed": bool(zone.get("is_play_allowed")),
            "is_pause_allowed": bool(zone.get("is_pause_allowed")),
            "is_previous_allowed": bool(zone.get("is_previous_allowed")),
            "is_next_allowed": bool(zone.get("is_next_allowed")),
            "is_seek_allowed": bool(zone.get("is_seek_allowed")),
            "shuffle": bool(settings.get("shuffle")),
            "auto_radio": bool(settings.get("auto_radio")),
            "loop": settings.get("loop", "disabled"),
            "queue_items_remaining": zone.get("queue_items_remaining", 0),
            "queue_time_remaining": zone.get("queue_time_remaining", 0),
            "seek_position": zone.get("seek_position") or now.get("seek_position") or 0,
            "length": now.get("length") or 0,
            "title": clean_text(lines.get("line1")),
            "artist": clean_text(lines.get("line2")),
            "album": clean_text(lines.get("line3")),
            "art": self._image_url(image_key) if image_key else "",
            "outputs": outputs,
        }

    def output(self, output: dict) -> dict:
        controls = output.get("source_controls") or []
        return {
            "output_id": output.get("output_id", ""),
            "zone_id": output.get("zone_id", ""),
            "display_name": clean_text(output.get("display_name")),
            "volume": _volume(output),
            # Roon lists an output as groupable with itself, which is noise to
            # a UI offering "add this to the group".
            "can_group_with_output_ids": [
                o for o in (output.get("can_group_with_output_ids") or [])
                if o != output.get("output_id")
            ],
            "supports_standby": any(c.get("supports_standby") for c in controls),
            "source_status": (controls[0].get("status") if controls else ""),
            "source_name": clean_text(controls[0].get("display_name")) if controls else "",
        }


def as_dict(response):
    """pyroon returns the raw header string when a reply carries no JSON body.

    Callers that only ever expected a dict crashed on those with
    "'str' object has no attribute 'get'". Normalise here instead.
    """
    if isinstance(response, dict):
        return response
    return {}


def response_error(response):
    """Human-readable reason for a reply that was not a JSON object."""
    if isinstance(response, dict):
        return None
    if response is None:
        return "No reply from the core"
    line = str(response).strip().splitlines()[0][:120]
    if "InvalidItemKey" in line:
        # Roon mints new item_keys whenever the browse stack moves; a key from
        # before a pop is dead. Say that, rather than echoing the protocol.
        return "That item has expired — the list moved on. Try again."
    return line or "Unexpected reply"


def _dedupe_adjacent(values) -> list:
    out = []
    for value in values:
        if not out or out[-1] != value:
            out.append(value)
    return out


def sort_zones(zones: list[dict]) -> list[dict]:
    """Playing zones first, then by name — the order a user scans for."""
    rank = {"playing": 0, "loading": 1, "paused": 2, "stopped": 3}
    return sorted(
        zones,
        key=lambda z: (rank.get(z.get("state"), 4), z.get("display_name", "").lower()),
    )


# ------------------------------------------------------------------ backend


class RoonBackend:
    """Live connection to a Roon core."""

    def __init__(self, host=None, port=None, core_id=None):
        self._requested_host = host
        self._requested_port = port
        self._requested_core_id = core_id
        self._api = None
        self._serializer = None
        self._session = load_session()
        self._browse_zone = ""
        self._levels: list[dict] = []
        self._roots: list[dict] = []
        self._queue_subs: set = set()
        self._queues: dict = {}
        self.stopped = False
        self.endpoints = None
        self._last_titles: dict = {}
        self._history = None
        self._favourites = None
        self._history_enabled = True
        self.mpris = None
        self._mpris_zone = None
        self._mpris_pinned = ""

    # -- connection --------------------------------------------------------

    def connect(self):
        """Returns None once connected, or a reason string to retry on."""
        from roonapi import RoonApi, RoonDiscovery

        host, port = self._requested_host, self._requested_port
        core_id = self._requested_core_id or self._session.get("core_id")
        used_cached_host = False

        if not host:
            host = self._session.get("host")
            port = self._session.get("port")
            used_cached_host = bool(host)

        if not host:
            emit({"type": "status", "state": "discovering",
                  "message": "Looking for a Roon core on the network"})
            discovery = RoonDiscovery(core_id)
            try:
                host, port = discovery.first()
            finally:
                discovery.stop()

        if not host:
            return "No Roon core found. Set the core host in the widget settings."

        port = port or 9330
        emit({"type": "status", "state": "connecting",
              "message": "Connecting to %s" % host, "host": host, "port": port})

        token = self._session.get("token")
        if not token:
            emit({"type": "status", "state": "waiting_authorization",
                  "message": "Enable \"Omarchy\" in Roon → Settings → Extensions"})

        for attribute in ("_get_zones", "_get_outputs"):
            if not hasattr(RoonApi, attribute):
                # We call these to work around pyroon seeding its state before
                # the socket registers. If an upgrade removes them the symptom
                # would be zones that never populate, which is a miserable
                # thing to debug from the outside.
                return ("This roonapi build is missing RoonApi.%s — the plugin pins "
                        "roonapi==0.1.6 for exactly this reason" % attribute)

        # blocking_init would hang here forever while the user walks over to
        # the Roon app, so poll `ready` and keep reporting status instead.
        api = RoonApi(APPINFO, token, host, int(port), blocking_init=False)
        self._api = api
        self._serializer = ZoneSerializer(self._image_url)

        # Without a token we are waiting on a human to click Enable, which is
        # worth minutes. With one, the only thing that can be slow is an
        # unreachable host, and that deserves to fail fast and retry.
        deadline = time.monotonic() + (30 if token else 300)
        while not api.ready and time.monotonic() < deadline:
            time.sleep(0.2)

        if not api.ready:
            api.stop()
            self._api = None
            if token:
                # A remembered address that no longer answers: forget it so the
                # next attempt rediscovers instead of retrying a dead host.
                if used_cached_host:
                    self._session.pop("host", None)
                    self._session.pop("port", None)
                    save_session(self._session)
                return "No answer from %s" % host
            return "Not authorized yet — enable \u201cOmarchy\u201d in Roon \u2192 Settings \u2192 Extensions"

        self._session.update({
            "host": api.host,
            "port": int(port),
            "token": api.token,
            "core_id": api.core_id,
            "core_name": api.core_name,
        })
        save_session(self._session)

        emit({"type": "status", "state": "ready", "message": "Connected",
              "core": api.core_name or host, "host": api.host})

        self._seed_state(api)
        api.register_state_callback(self._on_state)
        self.emit_history()
        self.push_zones()
        if self.endpoints:
            self.endpoints.notify()
        return None

    def api_healthy(self):
        """Whether the core is still answering.

        pyroon flips `ready` off when its socket drops and tries to bring it
        back on its own; if it succeeds this never fires, and if it does not
        the supervisor below takes over.
        """
        api = self._api
        return api is not None and bool(getattr(api, "ready", False))

    def drop_connection(self, reason):
        """Let go of a core that has gone away, and say so.

        Everything the plugin holds is keyed to the session that just ended.
        Browse item_keys are minted per level and are dead the moment the core
        restarts; the queue subscriptions are registered against a socket that
        no longer exists; and the zone list describes a state nobody is in any
        more. Keeping any of it would make the next connection lie.
        """
        api, self._api = self._api, None
        if api is not None:
            try:
                api.stop()
            except Exception as exc:  # noqa: BLE001
                log("stopping the old connection failed: %r" % exc)

        self._levels = []
        self._roots = []
        self._queue_subs = set()
        self._queues = {}
        self._last_titles = {}
        emit({"type": "zones", "zones": []})
        emit({"type": "status", "state": "error", "message": reason})
        if self.mpris:
            try:
                self.mpris.update(None)
            except Exception as exc:  # noqa: BLE001
                log("mpris teardown failed: %r" % exc)

    @staticmethod
    def _seed_state(api):
        """Re-fetch the full zone/output snapshot now that the socket is up.

        pyroon seeds these inside RoonApi.__init__, but with blocking_init=False
        that runs before registration completes, so the request fails ("Connection
        is not (yet) ready!"). The first message that then lands for a zone can be
        a partial zones_seek_changed, which pyroon stores wholesale — leaving a
        zone with no display_name and no outputs for as long as nothing sends a
        full update. Seeding here, after ready, closes that window.
        """
        for attr, fetch in (("_zones", "_get_zones"), ("_outputs", "_get_outputs")):
            getter = getattr(api, fetch, None)
            if getter is None:
                continue
            try:
                value = getter()
            except Exception as exc:  # noqa: BLE001 - a failed seed is not fatal
                log("%s failed: %r" % (fetch, exc))
                continue
            if value:
                setattr(api, attr, value)

    def _image_url(self, image_key: str) -> str:
        if not self._api or not image_key:
            return ""
        return self._api.get_image(image_key, scale="fit", width=ART_SIZE, height=ART_SIZE)

    def _on_state(self, event, changed_ids) -> None:
        # Roon fires seek updates once a second per zone; those carry no new
        # structure, so collapse everything into one full snapshot push. The
        # payload is small and it keeps the QML side free of merge logic.
        self.push_zones()

    def push_zones(self) -> None:
        if not self._api or not self._serializer:
            return
        try:
            zones = [self._serializer.zone(z) for z in self._api.zones.values()]
        except Exception as exc:  # noqa: BLE001 - a bad snapshot must not kill the bridge
            log("zone serialization failed:", exc)
            return
        self._announce_zones(zones)

    def _announce_zones(self, zones):
        """Everything that follows a zone snapshot, whatever produced it.

        Shared with the mock so the desktop player, the play log and the
        endpoint probes all run on the same path in both — an override that
        skipped this was how mock MPRIS ended up publishing an empty player.
        """
        emit({"type": "zones", "zones": sort_zones(zones)})

        # Keep the desktop's idea of "the thing playing" in step.
        self._mpris_zone = self._mpris_target(zones)
        if self.mpris:
            self.mpris.publish_changes()

        titles = {z["zone_id"]: (z["state"], z["title"]) for z in zones}
        if titles != self._last_titles:
            for zone in zones:
                previous = self._last_titles.get(zone["zone_id"])
                if not previous or previous[1] != zone["title"]:
                    self.record_history(zone)
            self._last_titles = titles
            if self.endpoints:
                self.endpoints.notify()

    # -- transport ---------------------------------------------------------

    def control(self, zone, action):
        self._api.playback_control(zone, action)

    def seek(self, zone, seconds, method="absolute"):
        self._api.seek(zone, int(seconds), method)

    def shuffle(self, zone, on):
        self._api.shuffle(zone, bool(on))

    def repeat(self, zone, mode):
        self._api.repeat(zone, mode)

    def auto_radio(self, zone, on):
        """Roon Radio. pyroon does not wrap it; the setting is standard."""
        return self._api._request(
            SERVICE_TRANSPORT + "/change_settings",
            {"zone_or_output_id": zone, "auto_radio": bool(on)})

    def mute(self, output, muted):
        self._api.mute(output, bool(muted))

    def volume(self, output, percent):
        self._api.set_volume_percent(output, max(0, min(100, int(percent))))

    def volume_step(self, output, delta):
        self._api.change_volume_percent(output, int(delta))

    def transfer(self, from_zone, to_zone):
        self._api.transfer_zone(from_zone, to_zone)

    def group(self, output_ids):
        self._api.group_outputs(list(output_ids))

    def ungroup(self, output_ids):
        self._api.ungroup_outputs(list(output_ids))

    def standby(self, output):
        self._api.standby(output)

    # -- browse ------------------------------------------------------------
    #
    # Roon's browse hierarchy is a stack: every browse_browse pushes a level
    # and returns a handle you then browse_load to page through. We mirror the
    # stack here so "back" is a pop rather than a replay from the root.

    def _load_level(self, offset=0):
        opts = {"hierarchy": "browse", "offset": int(offset), "count": PAGE_SIZE}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        return self._api.browse_load(opts)

    def _emit_browse(self, loaded, offset=0, complete=True):
        loaded = as_dict(loaded)
        info = loaded.get("list") or {}
        items = []
        for item in loaded.get("items") or []:
            image_key = item.get("image_key")
            items.append({
                "title": clean_text(item.get("title")),
                "subtitle": clean_text(item.get("subtitle")),
                "item_key": item.get("item_key", "") or "",
                "hint": item.get("hint", "") or "",
                "input_prompt": item.get("input_prompt") or None,
                "art": self._image_url(image_key) if image_key else "",
                "catalog": has_link_markup(item.get("subtitle"), item.get("title")),
            })
        # An album or artist level carries its own cover, its artist in the
        # subtitle and its track count. All three were being dropped, which is
        # why the most-visited screen in the plugin rendered as a plain list.
        level_art = info.get("image_key")
        emit({
            "type": "browse",
            "title": clean_text(info.get("title")),
            "subtitle": clean_text(info.get("subtitle")),
            "art": self._image_url(level_art) if level_art else "",
            "level": info.get("level", 0),
            "count": info.get("count", len(items)),
            "offset": offset,
            "hint": info.get("hint", "") or "",
            # Some results wrap an album in a container of the same name, so
            # the stack legitimately holds it twice. Show it once.
            "crumbs": _dedupe_adjacent(lvl.get("title", "") for lvl in self._levels),
            "items": items,
        })
        # Every path that shows a level lands here, so the follow-up load hangs
        # off this rather than off the dozen call sites above it.
        if complete and offset == 0:
            self._complete_level(loaded)

    def _after_browse(self, response, offset=0):
        """Turn a browse_browse response into whatever the UI should show next."""
        reason = response_error(response)
        if reason:
            emit({"type": "message", "is_error": True, "message": reason})
            return
        action = as_dict(response).get("action")
        if action == "list":
            info = as_dict(response).get("list") or {}
            self._levels.append({"title": info.get("title", "") or ""})
            self._emit_browse(self._load_level(offset), offset)
        elif action == "message":
            emit({"type": "message",
                  "is_error": bool(as_dict(response).get("is_error")),
                  "message": as_dict(response).get("message", "")})
        elif action == "replace_item":
            # An action ran in place (e.g. "Play Now"); refresh the level we
            # are still standing on rather than pushing a new one.
            self._emit_browse(self._load_level(0), 0)
        else:
            emit({"type": "message", "is_error": False, "message": "Done"})

    def _reset_to_root(self):
        """Pop the browse stack back to the top level and return its items."""
        opts = {"hierarchy": "browse", "pop_all": True}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        response = self._api.browse_browse(opts)
        info = as_dict(response).get("list") or {}
        self._levels = [{"title": info.get("title", "Browse") or "Browse"}]
        return self._load_level(0)

    def browse_home(self, zone=""):
        self._browse_zone = zone or self._browse_zone
        loaded = self._reset_to_root()
        self._emit_roots(loaded)
        self._emit_browse(loaded, 0)

    def browse_root(self, title, index=-1, zone=""):
        """Jump to a top-level category from any depth.

        Addressed by title, not by item_key, and that is not a style choice:
        popping the browse stack makes Roon mint new item_keys for the level
        it reloads, so any key the UI captured earlier is dead by the time we
        get here. Reset first, then match against the keys we just received.
        """
        if zone:
            self._browse_zone = zone
        loaded = self._reset_to_root()
        self._emit_roots(loaded)

        target = None
        if title:
            for item in self._roots:
                if item["title"] == title:
                    target = item
                    break
        if target is None and 0 <= index < len(self._roots):
            target = self._roots[index]

        if target is None:
            self._emit_browse(loaded, 0)
            return
        self.browse_item(target["item_key"])

    def _emit_roots(self, loaded):
        items = []
        for item in (loaded or {}).get("items") or []:
            if item.get("hint") == "header" or not item.get("item_key"):
                continue
            items.append({
                "title": clean_text(item.get("title")),
                "subtitle": clean_text(item.get("subtitle")),
                "item_key": item.get("item_key", "") or "",
                "hint": item.get("hint", "") or "",
            })
        # Keys must always be refreshed — browse_root resolves against these,
        # and Roon mints new ones on every reset. But the *UI* only cares about
        # the titles, so emitting an identical list would rebuild the nav model
        # for nothing, which reads as a flicker in the left pane.
        titles = [item["title"] for item in items]
        changed = titles != [item["title"] for item in self._roots]
        self._roots = items
        if changed:
            emit({"type": "roots", "items": items})

    def browse_item(self, item_key, zone="", user_input=None):
        if zone:
            self._browse_zone = zone
        opts = {"hierarchy": "browse", "item_key": item_key}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        if user_input is not None:
            opts["input"] = user_input
        self._after_browse(self._api.browse_browse(opts))

    def play_default(self, item_key, zone="", label=""):
        """Run an item's obvious action without making the user pick it.

        "Play Album" is an action_list: opening it yields Play Now, Add Next,
        Queue and Start Radio. Pressing play on a record should not cost two
        keystrokes and a menu, so this descends, takes Play Now, runs it, and
        pops back so the browse stack still matches the screen behind it.
        """
        if zone:
            self._browse_zone = zone
        loaded = self._enter(item_key)
        if loaded is None:
            # Not an action list after all — open it the ordinary way.
            self.browse_item(item_key, zone)
            return

        items = loaded.get("items") or []
        chosen = None
        for item in items:
            if (item.get("title") or "").strip().lower() == "play now":
                chosen = item
                break
        if chosen is None:
            for item in items:
                if item.get("hint") == "action":
                    chosen = item
                    break
        if chosen is None:
            # Nothing runnable down there: show the menu rather than nothing.
            self._emit_browse(loaded)
            return

        opts = {"hierarchy": "browse", "item_key": chosen.get("item_key", "")}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        response = self._api.browse_browse(opts)
        reason = response_error(response)
        if reason:
            emit({"type": "message", "is_error": True, "message": reason})
        else:
            emit({"type": "message", "is_error": False,
                  "message": "Playing " + (label or clean_text(loaded.get("list", {}).get("title")))})
        # Back to the level the user is looking at. The action pushed nothing
        # they asked for, so it should not be left on the stack.
        self.browse_back()

    def _enter(self, item_key):
        """Descend one level, without emitting it.

        Multi-step navigation (find_album) walks through intermediate levels
        that the user has no interest in. Emitting those is what made opening
        a remembered album flash a wrapper screen on the way past.
        """
        opts = {"hierarchy": "browse", "item_key": item_key}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        response = self._api.browse_browse(opts)
        if as_dict(response).get("action") != "list":
            return None
        info = as_dict(response).get("list") or {}
        self._levels.append({"title": info.get("title", "") or ""})
        return as_dict(self._load_level(0))

    def _browse_into(self, item_key):
        opts = {"hierarchy": "browse", "item_key": item_key}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        response = self._api.browse_browse(opts)
        if as_dict(response).get("action") != "list":
            return None
        return as_dict(self._load_level(0))

    @staticmethod
    def _find_input_row(loaded):
        for item in (loaded or {}).get("items") or []:
            if item.get("input_prompt") and item.get("item_key"):
                return item
        return None

    def _open_search(self, text):
        """Run a search and return its loaded level, emitting nothing.

        Split out of search() so find_album() can look at the results and keep
        going, instead of the UI flashing a search page on the way past.
        """
        loaded = self._reset_to_root()
        self._emit_roots(loaded)

        row = self._find_input_row(loaded)
        if row is None:
            for candidate in list(self._roots):
                if candidate.get("hint") != "list":
                    continue
                sub = self._browse_into(candidate["item_key"])
                row = self._find_input_row(sub)
                if row:
                    self._levels.append({"title": candidate["title"]})
                    break
                # Wrong branch — unwind before trying the next one.
                loaded = self._reset_to_root()

        if row is None:
            return None

        opts = {"hierarchy": "browse", "item_key": row["item_key"], "input": text}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        response = self._api.browse_browse(opts)
        if as_dict(response).get("action") != "list":
            return None
        info = as_dict(response).get("list") or {}
        self._levels.append({"title": info.get("title", "") or ""})
        return as_dict(self._load_level(0))

    def search(self, text, zone=""):
        """Search from anywhere, without relying on a captured item_key.

        Roon regenerates item_keys whenever the browse stack moves, so a key
        the UI grabbed when it drew the Search row can be dead by the time the
        user finishes typing — which is how a search that works at the
        protocol level returns nothing in the UI.

        The search Roon exposes is global: results already include the
        streaming catalogue, so there is nothing extra to do for Qobuz.
        """
        if zone:
            self._browse_zone = zone
        loaded = self._open_search(text)
        if loaded is None:
            emit({"type": "message", "is_error": True,
                  "message": "This core exposes no search"})
            return
        self._emit_browse(loaded, 0)

    @staticmethod
    def _norm(value):
        return re.sub(r"[^a-z0-9]", "", str(value or "").lower())

    def _match_album_row(self, loaded, album, artist):
        want = self._norm(album)
        if not want:
            return None
        rows = [i for i in (loaded or {}).get("items") or [] if i.get("item_key")]
        exact = [i for i in rows if self._norm(i.get("title")) == want]
        if not exact:
            return None
        if len(exact) == 1:
            return exact[0]
        # Several records share the title — prefer the one crediting the
        # artist we remembered. Roon gives us the *track* artist, which for a
        # record with guests is a long list, so match on the first name only.
        primary = self._norm((artist or "").split("/")[0])
        for row in exact:
            if primary and primary in self._norm(row.get("subtitle")):
                return row
        return exact[0]

    def find_album(self, album, artist="", zone=""):
        """Open a remembered album, rather than dumping the user in search.

        A history row has no Roon item_key — we only ever saw the text on the
        now-playing screen — so the album has to be found again. Searching and
        stopping at the results page is what made clicking one feel random:
        you asked for a record and got a list of categories.

        The query is the album title alone. Including Roon's artist string
        made it worse, not better: it is the track artist, so on a record with
        features it is five names long and drags in unrelated matches.
        """
        if zone:
            self._browse_zone = zone
        if not album:
            return

        loaded = self._open_search(album)
        if loaded is None:
            emit({"type": "message", "is_error": True,
                  "message": "This core exposes no search"})
            return

        target = self._match_album_row(loaded, album, artist)

        if target is None:
            # Not among the headline hits; look inside the Albums bucket.
            bucket = None
            for item in loaded.get("items") or []:
                if (item.get("title") or "").strip().lower() == "albums" and item.get("item_key"):
                    bucket = item
                    break
            if bucket is not None:
                sub = self._browse_into(bucket["item_key"])
                target = self._match_album_row(sub, album, artist)
                if target is None:
                    # Still closer than a search page: show the album matches.
                    self._emit_browse(as_dict(sub), 0)
                    emit({"type": "message", "is_error": False,
                          "message": "No exact match for \u201c%s\u201d" % album})
                    return

        if target is None:
            self._emit_browse(loaded, 0)
            emit({"type": "message", "is_error": False,
                  "message": "No exact match for \u201c%s\u201d" % album})
            return

        level = self._enter(target["item_key"])
        if level is None:
            self._emit_browse(loaded, 0)
            emit({"type": "message", "is_error": False,
                  "message": "Could not open \u201c%s\u201d" % album})
            return

        # Some results wrap the album in a single-row container before the
        # track list; step through it so the user lands on the record. Still
        # nothing emitted, so none of this is ever on screen.
        rows = [i for i in level.get("items") or [] if i.get("item_key")]
        if len(rows) == 1 and self._norm(rows[0].get("title")) == self._norm(album):
            deeper = self._enter(rows[0]["item_key"])
            if deeper is not None:
                level = deeper

        self._emit_browse(level, 0)

    def browse_back(self):
        if len(self._levels) <= 1:
            self.browse_home(self._browse_zone)
            return
        opts = {"hierarchy": "browse", "pop_levels": 1}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        response = self._api.browse_browse(opts)
        self._levels.pop()
        # pop_levels lands on an existing level, so load it without pushing.
        if as_dict(response).get("action") == "list":
            self._emit_browse(self._load_level(0), 0)
        else:
            self.browse_home(self._browse_zone)

    def browse_page(self, offset):
        self._emit_browse(self._load_level(int(offset)), int(offset))

    def _complete_level(self, loaded):
        """Pull the rest of a short level, then say where each letter starts.

        The first page is emitted before this runs, so the grid paints at once
        and the remainder arrives as an append a moment later — the browser
        already knows how to merge that without moving the cursor.
        """
        loaded = as_dict(loaded)
        info = loaded.get("list") or {}
        count = int(info.get("count") or 0)
        have = len(loaded.get("items") or [])
        if count <= have or count > FULL_LOAD_LIMIT:
            return

        opts = {"hierarchy": "browse", "offset": have, "count": count - have}
        if self._browse_zone:
            opts["zone_or_output_id"] = self._browse_zone
        try:
            rest = as_dict(self._api.browse_load(opts))
        except Exception as exc:  # noqa: BLE001
            log("full load failed: %r" % exc)
            return

        rest_items = rest.get("items") or []
        if not rest_items:
            return
        self._emit_browse(rest, have, complete=False)
        self._emit_letters([i.get("title") for i in loaded.get("items") or []]
                           + [i.get("title") for i in rest_items])

    def _emit_letters(self, titles):
        """First row index for each initial letter, in Roon's own sort order.

        Roon returns the level already sorted, so this reads the order it gave
        rather than imposing one — which is why a rail built from it lands
        where the list actually goes.
        """
        emit({"type": "letters", "items": letter_marks(titles),
              "total": len(titles)})


    def raw_zones(self):
        """Emit the core's zone payload untouched.

        The serializer deliberately flattens and cleans; this is the escape
        hatch for answering "does Roon actually send us X?" without attaching
        a second extension to the core.
        """
        zones = self._api.zones if self._api else {}
        emit({"type": "raw", "what": "zones", "data": zones})

    def raw_outputs(self):
        outputs = self._api.outputs if self._api else {}
        emit({"type": "raw", "what": "outputs", "data": outputs})

    # -- play history ------------------------------------------------------
    #
    # Roon exposes no history of any kind: not "recently played", not
    # "recently added". Settings offers only "Artists Sort By" and
    # "Composers Sort By", and the Albums hierarchy is alphabetical with no
    # sort control, so there is nothing to read.
    #
    # What the bridge *can* do is remember. It already sees every track change
    # in every zone, so it writes them down. That yields a real Recently
    # Played from the moment the plugin is installed — ours, not Roon's, and
    # the UI says so.

    @staticmethod
    def _album_key(entry):
        """Identity for "the record I am listening to".

        Not album+artist: Roon reports the *track* artist, so a guest feature
        changes it mid-record and the same album splits into several rows.
        The cover is the reliable discriminator — one image_key per album — so
        it identifies the record, and two different albums that happen to
        share a title still get their own entry. Artist is the fallback for
        anything with no artwork, and a radio stream with no album at all
        falls back to its track title.
        """
        album = (entry.get("album") or entry.get("title") or "").strip().lower()
        art = (entry.get("art") or "").strip()
        if art:
            return album + "\u0000" + art
        artist = (entry.get("artist") or "").strip().lower()
        # First credited name only, so featured guests do not fork the key.
        primary = artist.split("/")[0].strip()
        return album + "\u0000" + primary

    def _normalise_history(self, entries):
        """Collapse a list of plays into one row per album, newest first.

        Roon's own Recent Activity is a wall of album covers, not a track log,
        and that is the right unit: forty tracks from one record is one thing
        you listened to. Also migrates the track-level file written by the
        first version of this feature.
        """
        collapsed = []
        seen = {}
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            key = self._album_key(entry)
            existing = seen.get(key)
            if existing is not None:
                existing["tracks"] = existing.get("tracks", 1) + entry.get("tracks", 1)
                existing["at"] = max(existing.get("at", 0), entry.get("at", 0))
                if not existing.get("art") and entry.get("art"):
                    existing["art"] = entry["art"]
                continue
            row = {
                "album": entry.get("album") or entry.get("title") or "",
                "artist": entry.get("artist") or "",
                "title": entry.get("title") or "",
                "art": entry.get("art") or "",
                "zone": entry.get("zone") or "",
                "at": entry.get("at", 0),
                "tracks": entry.get("tracks", 1),
            }
            seen[key] = row
            collapsed.append(row)
        collapsed.sort(key=lambda r: r.get("at", 0), reverse=True)
        return collapsed

    def _load_history(self):
        if self._history is not None:
            return self._history
        try:
            with open(HISTORY_FILE, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            data = []
        self._history = self._normalise_history(data if isinstance(data, list) else [])
        return self._history

    def _save_history(self):
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        tmp = HISTORY_FILE + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(self._history[:HISTORY_LIMIT], handle)
            os.replace(tmp, HISTORY_FILE)
        except OSError as exc:
            log("history save failed: %r" % exc)

    def set_history_enabled(self, on):
        self._history_enabled = bool(on)

    def record_history(self, zone):
        """Fold a track into its album's entry, moving that album to the top."""
        if not self._history_enabled:
            return
        title = zone.get("title") or ""
        if not title or zone.get("state") not in ("playing", "loading"):
            return
        history = self._load_history()
        entry = {
            # A radio stream has no album; its track title is the best label.
            "album": zone.get("album") or title,
            "artist": zone.get("artist") or "",
            "title": title,
            "art": zone.get("art") or "",
            "zone": zone.get("display_name") or "",
            "at": int(time.time()),
            "tracks": 1,
        }
        key = self._album_key(entry)

        existing = None
        for index, row in enumerate(history):
            if self._album_key(row) == key:
                existing = history.pop(index)
                break

        if existing is not None:
            # Same record still playing: count the track, refresh the time,
            # and float it back to the front rather than duplicating it.
            existing["tracks"] = existing.get("tracks", 1) + 1
            existing["at"] = entry["at"]
            existing["title"] = title
            existing["zone"] = entry["zone"]
            if entry["art"]:
                existing["art"] = entry["art"]
            entry = existing

        history.insert(0, entry)
        del history[HISTORY_LIMIT:]
        self._history = history
        self._save_history()
        self.emit_history()

    def emit_history(self):
        emit({"type": "history", "items": self._load_history()[:100]})

    def clear_history(self):
        self._history = []
        self._save_history()
        self.emit_history()

    # -- favourites -------------------------------------------------------
    #
    # Roon's extension API has no favourites. There is no such hierarchy in
    # the browse tree, and an album's action list is Play Now / Add Next /
    # Queue / Start Radio and nothing else — the heart in the Roon app is not
    # reachable from out here. So this is the plugin's own list, kept the way
    # the recently-played log is kept, and labelled as the plugin's so nobody
    # expects it in the Roon app. Same album identity as the history: the
    # cover when there is one, the first credited artist when there is not.

    def _load_favourites(self):
        if self._favourites is not None:
            return self._favourites
        try:
            with open(FAVOURITES_FILE, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            data = []
        rows = []
        for entry in data if isinstance(data, list) else []:
            if not isinstance(entry, dict):
                continue
            rows.append({
                "album": entry.get("album") or "",
                "artist": entry.get("artist") or "",
                "art": entry.get("art") or "",
                "at": entry.get("at", 0),
            })
        rows.sort(key=lambda r: r.get("at", 0), reverse=True)
        self._favourites = rows
        return rows

    def _save_favourites(self):
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        tmp = FAVOURITES_FILE + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(self._favourites[:FAVOURITES_LIMIT], handle)
            os.replace(tmp, FAVOURITES_FILE)
        except OSError as exc:
            log("favourites save failed: %r" % exc)

    def favourite_toggle(self, album, artist, art):
        """Add or remove one record, and say which happened."""
        album = (album or "").strip()
        if not album:
            return
        entry = {"album": album, "artist": (artist or "").strip(),
                 "art": art or "", "at": int(time.time())}
        key = self._album_key(entry)
        rows = [r for r in self._load_favourites() if self._album_key(r) != key]
        added = len(rows) == len(self._load_favourites())
        if added:
            rows.insert(0, entry)
        self._favourites = rows
        self._save_favourites()
        self.emit_favourites()
        emit({"type": "message", "is_error": False,
              "message": ("Added " if added else "Removed ") + album
                         + (" to favourites" if added else " from favourites")})

    def emit_favourites(self):
        emit({"type": "favourites", "items": self._load_favourites()})

    def clear_favourites(self):
        self._favourites = []
        self._save_favourites()
        self.emit_favourites()

    def raw_browse(self, opts=None, load=True):
        """Run an arbitrary browse call and emit both replies untouched.

        The serializer keeps six fields per item and drops the rest; this is
        how we find out what the rest actually are, and how we probe
        hierarchies the UI does not use yet.
        """
        opts = dict(opts or {})
        opts.setdefault("hierarchy", "browse")
        browsed = self._api.browse_browse(opts)
        out = {"opts": opts, "browse": browsed}
        if load:
            load_opts = {"hierarchy": opts["hierarchy"],
                         "offset": int(opts.pop("load_offset", 0)),
                         "count": int(opts.pop("load_count", 20))}
            if opts.get("zone_or_output_id"):
                load_opts["zone_or_output_id"] = opts["zone_or_output_id"]
            try:
                out["load"] = self._api.browse_load(load_opts)
            except Exception as exc:  # noqa: BLE001
                out["load_error"] = repr(exc)
        emit({"type": "raw", "what": "browse", "data": out})

    def queue(self, zone=""):
        """Subscribe to a zone's queue and stream it to the UI.

        Roon pushes the upcoming tracks per zone through the transport
        service's queue endpoint. One subscription per zone, kept for the
        session — pyroon exposes no unsubscribe, so re-subscribing on every
        zone switch would pile them up.
        """
        target = zone or (self.active_zone_id() or "")
        if not target:
            return
        if target in self._queue_subs:
            # Already streaming; re-emit what we last saw so a newly opened
            # view fills immediately rather than waiting for the next change.
            cached = self._queues.get(target)
            if cached is not None:
                emit({"type": "queue", "zone_id": target, "items": cached})
            return

        def on_queue(payload, zone_id=target):
            items = []
            for item in (payload or {}).get("items") or []:
                lines = item.get("three_line") or item.get("two_line") or item.get("one_line") or {}
                image_key = item.get("image_key")
                items.append({
                    "queue_item_id": item.get("queue_item_id"),
                    "title": clean_text(lines.get("line1")),
                    "artist": clean_text(lines.get("line2")),
                    "album": clean_text(lines.get("line3")),
                    "length": item.get("length") or 0,
                    "art": self._image_url(image_key) if image_key else "",
                })
            self._queues[zone_id] = items
            emit({"type": "queue", "zone_id": zone_id, "items": items})

        self._queue_subs.add(target)
        self._api.register_queue_callback(on_queue, target)

    def _mpris_target(self, zones):
        """The one zone MPRIS speaks for.

        MPRIS has no notion of rooms and a media key means "the thing I am
        listening to", so this follows the same rule the UI uses: whatever is
        playing, else whatever has a track loaded, else the first zone.

        Once a media key has acted on a room, that room is pinned. Without it,
        pausing meant nothing was playing, the rule picked a different room,
        and the next press of the same key resumed somewhere else entirely.
        """
        if self._mpris_pinned:
            for zone in zones:
                if zone.get("zone_id") == self._mpris_pinned:
                    return zone
            self._mpris_pinned = ""   # that room went away

        for zone in zones:
            if zone.get("state") in ("playing", "loading"):
                return zone
        for zone in zones:
            if zone.get("title"):
                return zone
        return zones[0] if zones else None

    def mpris_zone(self):
        zone = dict(self._mpris_zone or {})
        if zone:
            # MPRIS volume is a fraction; Roon's is a per-output percentage.
            outputs = zone.get("outputs") or []
            for output in outputs:
                if output.get("volume"):
                    zone["_volume_fraction"] = output["volume"].get("percent", 0) / 100.0
                    zone["_volume_output"] = output["output_id"]
                    break
        return zone

    def mpris_command(self, action, arg):
        """Route a desktop media action onto the zone MPRIS speaks for."""
        zone = self._mpris_zone or {}
        zone_id = zone.get("zone_id", "")
        if zone_id and action in ("play", "pause", "playpause", "next", "previous",
                                  "stop", "seek_absolute", "seek_relative"):
            # Acting on a room claims it, and tells the UI so both agree on
            # which room "the thing I am listening to" means.
            if zone_id != self._mpris_pinned:
                self._mpris_pinned = zone_id
                emit({"type": "active_zone", "zone_id": zone_id, "source": "mpris"})
        try:
            if action in ("play", "pause", "playpause", "next", "previous", "stop"):
                if not zone_id:
                    return
                self.control(zone_id, action)
            elif action == "seek_absolute" and zone_id:
                self.seek(zone_id, arg, "absolute")
                if self.mpris:
                    self.mpris.emit_seeked(arg)
            elif action == "seek_relative" and zone_id:
                self.seek(zone_id, arg, "relative")
            elif action == "shuffle" and zone_id:
                self.shuffle(zone_id, arg)
            elif action == "loop" and zone_id:
                self.repeat(zone_id, arg)
            elif action == "volume":
                output = self.mpris_zone().get("_volume_output")
                if output:
                    self.volume(output, arg)
            elif action == "raise":
                # The desktop asking to see the player: show the browser.
                emit({"type": "raise"})
        except Exception as exc:  # noqa: BLE001 - a media key must never crash us
            log("mpris command %s failed: %r" % (action, exc))

    def active_zone_id(self):
        """The zone the UI is most likely acting on: whatever is playing."""
        for zone_id, zone in (self._api.zones or {}).items() if self._api else []:
            if zone.get("state") in ("playing", "loading"):
                return zone_id
        for zone_id in (self._api.zones or {}) if self._api else []:
            return zone_id
        return ""

    def play_from_queue(self, zone, queue_item_id):
        """Jump to a track already sitting in the queue.

        pyroon wraps most of the transport service but not play_from_here, so
        the request goes out directly. Same socket, same request plumbing.
        """
        return self._api._request(
            SERVICE_TRANSPORT + "/play_from_here",
            {"zone_or_output_id": zone, "queue_item_id": queue_item_id})

    def raw_queue(self, zone=""):
        """One-shot queue subscription, to see what the queue service carries."""
        target = zone or self._browse_zone
        if not target:
            for zone_id, z in (self._api.zones or {}).items():
                if z.get("state") == "playing":
                    target = zone_id
                    break
        if not target:
            emit({"type": "raw", "what": "queue", "data": {}})
            return

        def on_queue(payload):
            emit({"type": "raw", "what": "queue", "data": payload})

        self._api.register_queue_callback(on_queue, target)

    def stop(self):
        self.stopped = True
        if self._api:
            try:
                self._api.stop()
            except Exception:  # noqa: BLE001
                pass


# --------------------------------------------------------------- mock mode


class MockBackend(RoonBackend):
    """Offline stand-in so the QML can be developed without a core.

    Mirrors the event shapes of the real backend exactly; nothing above the
    bridge should be able to tell the difference.
    """

    LIBRARY = {
        "": [("Library", "list", "lib"), ("Artists", "list", "art"), ("Albums", "list", "alb"),
             ("Genres", "list", "gen"), ("Playlists", "list", "pl"),
             ("Internet Radio", "list", "radio"), ("Search", "list", "search")],
        "lib": [("Artists", "list", "art"), ("Albums", "list", "alb"), ("Tracks", "list", "trk")],
        "art": [("Talk Talk", "list", "tt"), ("Julia Holter", "list", "jh"),
                ("Alice Coltrane", "list", "ac"), ("Arthur Russell", "list", "ar"),
                ("Grouper", "list", "gr"), ("Sam Amidon", "list", "sa")],
        "alb": [("Spirit of Eden", "list", "soe"), ("Laughing Stock", "list", "ls"),
                ("Have You in My Wilderness", "list", "hyimw"), ("Journey in Satchidananda", "list", "jis")],
        "gen": [("Ambient", "list", "amb"), ("Jazz", "list", "jazz"), ("Folk", "list", "folk")],
        "pl": [("Late Night", "list", "ln"), ("Sunday Morning", "list", "sm")],
        "radio": [("BBC Radio 3", "action", "r3"), ("NTS 1", "action", "nts1"), ("NTS 2", "action", "nts2")],
        "tt": [("Spirit of Eden", "list", "soe"), ("Laughing Stock", "list", "ls")],
        "jh": [("Have You in My Wilderness", "list", "hyimw"), ("Aviary", "list", "av")],
        "ac": [("Journey in Satchidananda", "list", "jis")],
        "soe": [("Play Now", "action", "play"), ("Add Next", "action", "next"),
                ("Queue", "action", "queue"), ("Start Radio", "action", "radio")],
        "ls": [("Play Now", "action", "play"), ("Queue", "action", "queue")],
        "hyimw": [("Play Now", "action", "play"), ("Queue", "action", "queue")],
        "jis": [("Play Now", "action", "play"), ("Queue", "action", "queue")],
    }

    def __init__(self, *_args, state="ready", **_kwargs):
        super().__init__()
        # Lets the setup screens be exercised without un-approving the real
        # extension in Roon, which is the only other way to see them again.
        self._forced_state = state
        self._zones = [
            {"zone_id": "z1", "display_name": "Living Room", "state": "playing",
             "title": "The Rainbow", "artist": "Talk Talk", "album": "Spirit of Eden",
             "length": 353, "seek_position": 47},
            {"zone_id": "z2", "display_name": "Kitchen", "state": "paused",
             "title": "Sea Calls Me Home", "artist": "Julia Holter", "album": "Have You in My Wilderness",
             "length": 231, "seek_position": 12},
            {"zone_id": "z3", "display_name": "Study", "state": "stopped",
             "title": "", "artist": "", "album": "", "length": 0, "seek_position": 0},
        ]
        self._volumes = {"z1": 42, "z2": 30, "z3": 55}
        self._muted = {"z1": False, "z2": False, "z3": False}
        self._stack = [""]

    def connect(self):
        if self._forced_state == "waiting":
            emit({"type": "status", "state": "waiting_authorization",
                  "message": "Enable \u201cOmarchy\u201d in Roon \u2192 Settings \u2192 Extensions",
                  "core": "Mock Core", "host": "127.0.0.1"})
            return None
        if self._forced_state == "nocore":
            emit({"type": "status", "state": "error",
                  "message": "No Roon core found. Set the core host in the widget settings. (retrying in 15s)"})
            return None
        if self._forced_state == "discovering":
            emit({"type": "status", "state": "discovering",
                  "message": "Looking for a Roon core on the network"})
            return None
        emit({"type": "status", "state": "ready", "message": "Connected (mock)",
              "core": "Mock Core", "host": "127.0.0.1"})
        self.push_zones()
        self._history = [
            {"album": "Spirit of Eden", "artist": "Talk Talk", "title": "The Rainbow",
             "art": "", "zone": "Living Room", "at": int(time.time()) - 120, "tracks": 4},
            {"album": "Have You in My Wilderness", "artist": "Julia Holter",
             "title": "Sea Calls Me Home", "art": "", "zone": "Kitchen",
             "at": int(time.time()) - 900, "tracks": 2},
            {"album": "Journey in Satchidananda", "artist": "Alice Coltrane",
             "title": "Journey in Satchidananda", "art": "", "zone": "Living Room",
             "at": int(time.time()) - 7200, "tracks": 5},
        ]
        self.emit_history()
        self.connect_endpoints()
        threading.Thread(target=self._tick, daemon=True).start()
        return None

    def _tick(self):
        while True:
            time.sleep(1)
            for zone in self._zones:
                if zone["state"] == "playing" and zone["length"]:
                    zone["seek_position"] = (zone["seek_position"] + 1) % zone["length"]
            self.push_zones()

    def push_zones(self):
        out = []
        for zone in self._zones:
            percent = self._volumes[zone["zone_id"]]
            out.append({
                **zone,
                "is_play_allowed": zone["state"] != "playing",
                "is_pause_allowed": zone["state"] == "playing",
                "is_previous_allowed": True,
                "is_next_allowed": True,
                "is_seek_allowed": bool(zone["length"]),
                "shuffle": False, "auto_radio": True, "loop": "disabled",
                "queue_items_remaining": 12, "queue_time_remaining": 2400,
                "art": "",
                "outputs": [{
                    "output_id": zone["zone_id"] + "-out",
                    "zone_id": zone["zone_id"],
                    "display_name": zone["display_name"],
                    "volume": {"type": "number", "min": 0, "max": 100, "step": 1,
                               "value": percent, "percent": percent,
                               "is_muted": self._muted[zone["zone_id"]],
                               "hard_limit_min": 0, "hard_limit_max": 100},
                    "can_group_with_output_ids": [
                        o["zone_id"] + "-out" for o in self._zones
                        if o["zone_id"] != zone["zone_id"]],
                    "supports_standby": zone["zone_id"] != "z3",
                    "source_status": "selected",
                    "source_name": zone["display_name"],
                }],
            })
        self._announce_zones(out)

    def _zone(self, zone_id):
        for zone in self._zones:
            if zone["zone_id"] == zone_id or zone["zone_id"] + "-out" == zone_id:
                return zone
        return self._zones[0]

    def control(self, zone, action):
        target = self._zone(zone)
        if action == "play":
            target["state"] = "playing"
        elif action == "pause":
            target["state"] = "paused"
        elif action == "stop":
            target["state"] = "stopped"
        elif action == "playpause":
            target["state"] = "paused" if target["state"] == "playing" else "playing"
        elif action in ("next", "previous"):
            target["seek_position"] = 0
        self.push_zones()

    def seek(self, zone, seconds, method="absolute"):
        target = self._zone(zone)
        base = target["seek_position"] if method == "relative" else 0
        target["seek_position"] = max(0, min(target["length"], base + int(seconds)))
        self.push_zones()

    def shuffle(self, zone, on):
        self.push_zones()

    def repeat(self, zone, mode):
        self.push_zones()

    def auto_radio(self, zone, on):
        self.push_zones()

    def mute(self, output, muted):
        self._muted[self._zone(output)["zone_id"]] = bool(muted)
        self.push_zones()

    def volume(self, output, percent):
        self._volumes[self._zone(output)["zone_id"]] = max(0, min(100, int(percent)))
        self.push_zones()

    def volume_step(self, output, delta):
        zone_id = self._zone(output)["zone_id"]
        self._volumes[zone_id] = max(0, min(100, self._volumes[zone_id] + int(delta)))
        self.push_zones()

    def transfer(self, from_zone, to_zone):
        self.push_zones()

    def group(self, output_ids):
        self.push_zones()

    def ungroup(self, output_ids):
        self.push_zones()

    def standby(self, output):
        self.push_zones()

    def _emit_mock_level(self):
        key = self._stack[-1]
        rows = self.LIBRARY.get(key, [])
        emit({
            "type": "browse",
            "title": key or "Roon",
            "subtitle": "",
            "level": len(self._stack) - 1,
            "count": len(rows),
            "offset": 0,
            "hint": "list",
            "crumbs": list(self._stack),
            "items": [{"title": t, "subtitle": "", "item_key": k, "hint": h,
                       "input_prompt": {"prompt": "Search"} if k == "search" else None,
                       "art": ""} for (t, h, k) in rows],
        })

    def _emit_mock_roots(self):
        items = [{"title": t, "subtitle": "", "item_key": k, "hint": h}
                 for (t, h, k) in self.LIBRARY[""]]
        # Same suppression as the real backend, so mock runs show the real
        # number of UI updates rather than a flattering one.
        changed = [i["title"] for i in items] != [i["title"] for i in self._roots]
        self._roots = items
        if changed:
            emit({"type": "roots", "items": items})

    def browse_home(self, zone=""):
        self._browse_zone = zone or self._browse_zone
        self._stack = [""]
        self._emit_mock_roots()
        self._emit_mock_level()

    def connect_endpoints(self):
        emit({"type": "endpoints", "data": {
            "z1": {"source": "linkplay", "display": "96 kHz · 24 bit",
                   "device": "Mock Streamer", "host": "127.0.0.1"},
            "z2": {"source": "sonos", "display": "FLAC",
                   "device": "Mock Speaker", "host": "127.0.0.2"},
        }})

    def browse_root(self, title, index=-1, zone=""):
        self._stack = [""]
        self._emit_mock_roots()
        target = None
        for (t, _h, k) in self.LIBRARY[""]:
            if t == title:
                target = k
                break
        if target is None and 0 <= index < len(self.LIBRARY[""]):
            target = self.LIBRARY[""][index][2]
        if target:
            self.browse_item(target)
        else:
            self._emit_mock_level()

    def browse_item(self, item_key, zone="", user_input=None):
        if item_key in self.LIBRARY:
            self._stack.append(item_key)
            self._emit_mock_level()
        else:
            emit({"type": "message", "is_error": False,
                  "message": "Mock: %s" % item_key})

    @staticmethod
    @staticmethod
    def find_album(self, album, artist="", zone=""):
        self.browse_item("soe")

    def queue(self, zone=""):
        emit({"type": "queue", "zone_id": zone or "z1", "items": [
            {"queue_item_id": 1, "title": "Eden", "artist": "Talk Talk",
             "album": "Spirit of Eden", "length": 386, "art": ""},
            {"queue_item_id": 2, "title": "Desire", "artist": "Talk Talk",
             "album": "Spirit of Eden", "length": 307, "art": ""},
            {"queue_item_id": 3, "title": "Inheritance", "artist": "Talk Talk",
             "album": "Spirit of Eden", "length": 335, "art": ""},
        ]})

    def play_from_queue(self, zone, queue_item_id):
        self.push_zones()

    def browse_back(self):
        if len(self._stack) > 1:
            self._stack.pop()
        self._emit_mock_level()

    def browse_page(self, offset):
        self._emit_mock_level()

    def stop(self):
        self.stopped = True


# ------------------------------------------------------------ endpoint watch


class EndpointWatcher(threading.Thread):
    """Asks each zone's physical endpoint what it is decoding.

    Roon will not tell us the format, so the devices are asked directly (see
    endpoints.py). That is network I/O with multi-second timeouts, so it lives
    on its own thread — a slow or absent speaker must never delay a transport
    command.

    Probing is driven by track changes rather than a tight poll: the format
    only changes when the music does.
    """

    DISCOVERY_TTL = 600
    IDLE_INTERVAL = 120

    def __init__(self, backend):
        super().__init__(daemon=True)
        self._backend = backend
        self._wake = threading.Event()
        self._devices: list = []
        self._matched: dict = {}
        self._results: dict = {}
        self._discovered_at = 0.0

    def notify(self):
        self._wake.set()

    def run(self):
        while not self._backend.stopped:
            try:
                self._tick()
            except Exception as exc:  # noqa: BLE001 - never take the bridge down
                log("endpoint watch failed: %r" % exc)
            self._wake.wait(self.IDLE_INTERVAL)
            self._wake.clear()

    def _zone_names(self) -> dict:
        api = getattr(self._backend, "_api", None)
        if not api:
            return {}
        return {zid: (z.get("display_name") or "") for zid, z in (api.zones or {}).items()}

    def _refresh_devices(self, zones):
        stale = time.monotonic() - self._discovered_at > self.DISCOVERY_TTL
        unknown = any(zid not in self._matched for zid in zones)
        if not stale and not unknown:
            return
        self._devices = endpoint_probes.discover()
        self._discovered_at = time.monotonic()
        overrides = endpoint_probes.load_overrides()
        self._matched = {
            zid: endpoint_probes.match_device(name, self._devices, overrides)
            for zid, name in zones.items()
        }
        log("endpoints: %d device(s), matched %d/%d zone(s)" % (
            len(self._devices),
            sum(1 for d in self._matched.values() if d),
            len(zones)))

    def _tick(self):
        zones = self._zone_names()
        if not zones:
            return
        self._refresh_devices(zones)

        api = getattr(self._backend, "_api", None)
        results = {}
        for zone_id, device in self._matched.items():
            if not device:
                continue
            # A paused zone still has the track loaded and Roon still shows
            # it, so it earns a reading. A stopped one reports whatever it
            # last played — possibly from a different source entirely.
            zone = (api.zones or {}).get(zone_id) if api else None
            if not zone or zone.get("state") == "stopped":
                continue
            info = endpoint_probes.probe(device)
            if info:
                results[zone_id] = info

        if results != self._results:
            self._results = results
            emit({"type": "endpoints", "data": results})


# --------------------------------------------------------------- dispatcher

HANDLERS = {
    "control":     lambda b, c: b.control(c["zone"], c.get("action", "playpause")),
    "seek":        lambda b, c: b.seek(c["zone"], c.get("seconds", 0), c.get("method", "absolute")),
    "shuffle":     lambda b, c: b.shuffle(c["zone"], c.get("on", True)),
    "auto_radio":  lambda b, c: b.auto_radio(c["zone"], c.get("on", True)),
    "repeat":      lambda b, c: b.repeat(c["zone"], c.get("mode", "loop")),
    "mute":        lambda b, c: b.mute(c["output"], c.get("mute", True)),
    "volume":      lambda b, c: b.volume(c["output"], c.get("percent", 0)),
    "volume_step": lambda b, c: b.volume_step(c["output"], c.get("delta", 0)),
    "transfer":    lambda b, c: b.transfer(c["from"], c["to"]),
    "group":       lambda b, c: b.group(c.get("outputs") or []),
    "ungroup":     lambda b, c: b.ungroup(c.get("outputs") or []),
    "standby":     lambda b, c: b.standby(c["output"]),
    "browse_home": lambda b, c: b.browse_home(c.get("zone", "")),
    "browse_root": lambda b, c: b.browse_root(c.get("title", ""), c.get("index", -1), c.get("zone", "")),
    "search":      lambda b, c: b.search(c.get("text", ""), c.get("zone", "")),
    "find_album":  lambda b, c: b.find_album(c.get("album", ""), c.get("artist", ""), c.get("zone", "")),
    "history":     lambda b, c: b.emit_history(),
    "history_clear": lambda b, c: b.clear_history(),
    "history_enabled": lambda b, c: b.set_history_enabled(c.get("on", True)),
    "favourites":  lambda b, c: b.emit_favourites(),
    "favourite_toggle": lambda b, c: b.favourite_toggle(
        c.get("album", ""), c.get("artist", ""), c.get("art", "")),
    "favourites_clear": lambda b, c: b.clear_favourites(),
    "browse_item": lambda b, c: b.browse_item(c["item_key"], c.get("zone", ""), c.get("input")),
    "browse_back": lambda b, c: b.browse_back(),
    "play_default": lambda b, c: b.play_default(
        c["item_key"], c.get("zone", ""), c.get("label", "")),
    "browse_page": lambda b, c: b.browse_page(c.get("offset", 0)),
    "refresh":     lambda b, c: b.push_zones(),
    "queue":       lambda b, c: b.queue(c.get("zone", "")),
    "play_from_queue": lambda b, c: b.play_from_queue(c["zone"], c["queue_item_id"]),
    "raw_zones":   lambda b, c: b.raw_zones(),
    "raw_outputs": lambda b, c: b.raw_outputs(),
    "raw_queue":   lambda b, c: b.raw_queue(c.get("zone", "")),
    "raw_browse":  lambda b, c: b.raw_browse(c.get("opts"), c.get("load", True)),
    "endpoints":   lambda b, c: b.endpoints and b.endpoints.notify(),
    "ping":        lambda b, c: None,
}


def worker(backend, commands: queue.Queue) -> None:
    """Runs commands off the stdin thread so a slow browse never blocks input."""
    while True:
        command = commands.get()
        if command is None:
            return
        cmd = command.get("cmd", "")
        handler = HANDLERS.get(cmd)
        if handler is None:
            emit({"type": "error", "id": command.get("id"),
                  "message": "unknown command: %s" % cmd})
            continue
        try:
            handler(backend, command)
            emit({"type": "result", "id": command.get("id"), "cmd": cmd, "ok": True})
        except Exception as exc:  # noqa: BLE001 - one bad command must not end the session
            log("command %s failed: %r" % (cmd, exc))
            emit({"type": "error", "id": command.get("id"), "cmd": cmd,
                  "message": str(exc)})


def main() -> int:
    parser = argparse.ArgumentParser(description="Roon <-> omarchy-shell stdio bridge")
    parser.add_argument("--host", default=os.environ.get("ROON_HOST") or None,
                        help="Roon core host; omit to auto-discover")
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("ROON_PORT") or 0) or None)
    parser.add_argument("--core-id", default=os.environ.get("ROON_CORE_ID") or None)
    parser.add_argument("--mock", action="store_true",
                        help="serve fabricated state; for UI work without a core")
    parser.add_argument("--no-mpris", action="store_true",
                        help="do not publish the active zone on D-Bus as an MPRIS player")
    parser.add_argument("--no-endpoints", action="store_true",
                        help="skip asking audio endpoints what they are decoding")
    parser.add_argument("--mock-state", default="ready",
                        choices=["ready", "waiting", "nocore", "discovering"],
                        help="which connection state the mock should report")
    args = parser.parse_args()

    backend_cls = MockBackend if args.mock else RoonBackend
    backend = (MockBackend(state=args.mock_state) if args.mock
               else RoonBackend(host=args.host, port=args.port, core_id=args.core_id))

    if not args.no_mpris:
        if MprisService is None:
            log("mpris unavailable, media keys will not work: %s" % _MPRIS_UNAVAILABLE)
        else:
            backend.mpris = MprisService(backend.mpris_command, backend.mpris_zone, log)
            backend.mpris.start()

    if not args.mock and not args.no_endpoints:
        backend.endpoints = EndpointWatcher(backend)
        backend.endpoints.start()

    commands: queue.Queue = queue.Queue()
    worker_thread = threading.Thread(target=worker, args=(backend, commands), daemon=True)
    worker_thread.start()

    # Connect off the main thread: discovery and authorization both block for
    # a long time, and stdin has to stay responsive throughout.
    threading.Thread(target=_connect_guarded, args=(backend,), daemon=True).start()

    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                command = json.loads(line)
            except ValueError:
                emit({"type": "error", "message": "malformed command line"})
                continue
            if not isinstance(command, dict):
                emit({"type": "error", "message": "command must be an object"})
                continue
            if command.get("cmd") == "quit":
                break
            commands.put(command)
    except KeyboardInterrupt:
        pass
    finally:
        # Drain whatever is still queued before tearing the connection down,
        # so a "quit" (or a closed stdin) doesn't silently drop commands the
        # caller already handed us.
        commands.put(None)
        worker_thread.join(timeout=10)
        if backend.mpris:
            backend.mpris.stop()
        backend.stop()
    return 0


HEALTH_INTERVAL = 5


def _connect_guarded(backend, health_interval=HEALTH_INTERVAL) -> None:
    """Keep a core connected, for as long as the bridge is running.

    A core that is merely asleep, still booting, or on a network the laptop
    has not joined yet is the normal case, not an error to give up on. The
    bridge stays alive either way, so retrying here is cheaper than making
    the user restart the shell.

    This used to return the moment it first succeeded, which made a Roon core
    that restarted — an update, a reboot, a Nucleus power-cycled — permanently
    fatal to a running plugin: no reconnect, no error, and a widget that went
    on looking connected while every command it sent went nowhere. So the loop
    does not end at the first success; it supervises.
    """
    delay = 15
    while not backend.stopped:
        try:
            reason = backend.connect()
        except Exception as exc:  # noqa: BLE001
            log("connect failed: %r" % exc)
            reason = str(exc)

        if reason is None:
            delay = 15
            _watch_connection(backend, health_interval)
            if backend.stopped:
                return
            # Straight back round: a core that has just restarted is usually
            # seconds from answering, and this is the one case where waiting
            # fifteen seconds is felt.
            continue

        if backend.stopped:
            return
        emit({"type": "status", "state": "error",
              "message": "%s (retrying in %ds)" % (reason, delay)})
        time.sleep(delay)
        delay = min(delay * 2, 300)


def _watch_connection(backend, health_interval=HEALTH_INTERVAL) -> None:
    """Block until the core stops answering, then let go of it."""
    while not backend.stopped:
        time.sleep(health_interval)
        if backend.stopped:
            return
        if backend.api_healthy():
            continue
        log("core stopped answering; reconnecting")
        backend.drop_connection("Lost the Roon core — reconnecting")
        return


if __name__ == "__main__":
    sys.exit(main())
