#!/usr/bin/env python3
"""Publish the active Roon zone on D-Bus as an MPRIS player.

This is the piece that makes the plugin better than a phone app rather than a
smaller copy of one. Roon has no presence on the desktop: hardware media keys
do nothing, `playerctl` cannot see it, and Omarchy's own media widget sits
three slots along in the same bar knowing nothing about it. Publishing the
zone as a standard MediaPlayer2 fixes all of that at once, without a single
new keybinding.

Deliberately hand-rolled on jeepney rather than pydbus or dbus-python: those
need compiled extensions or PyGObject, and the bridge runs in a small
virtualenv that should stay installable anywhere. jeepney is pure Python.

Quickshell can *consume* MPRIS but not publish it, which is why this lives in
the bridge rather than in QML.
"""

from __future__ import annotations

import os
import threading
import time

from jeepney import DBusAddress, HeaderFields, MessageType, new_error, new_method_return, new_signal
from jeepney.bus_messages import DBusNameFlags, message_bus
from jeepney.io.blocking import open_dbus_connection

PATH = "/org/mpris/MediaPlayer2"
ROOT_IFACE = "org.mpris.MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
INTROSPECT_IFACE = "org.freedesktop.DBus.Introspectable"
PEER_IFACE = "org.freedesktop.DBus.Peer"

TRACK_PREFIX = "/org/mpris/MediaPlayer2/roon/track/"
NO_TRACK = "/org/mpris/MediaPlayer2/TrackList/NoTrack"

INTROSPECTION = """<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg name="xml" type="s" direction="out"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
    <method name="GetMachineId"><arg name="machine_uuid" type="s" direction="out"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg name="interface" type="s" direction="in"/>
      <arg name="property" type="s" direction="in"/>
      <arg name="value" type="v" direction="out"/>
    </method>
    <method name="GetAll">
      <arg name="interface" type="s" direction="in"/>
      <arg name="properties" type="a{sv}" direction="out"/>
    </method>
    <method name="Set">
      <arg name="interface" type="s" direction="in"/>
      <arg name="property" type="s" direction="in"/>
      <arg name="value" type="v" direction="in"/>
    </method>
    <signal name="PropertiesChanged">
      <arg name="interface" type="s"/>
      <arg name="changed" type="a{sv}"/>
      <arg name="invalidated" type="as"/>
    </signal>
  </interface>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/>
    <method name="Previous"/>
    <method name="Pause"/>
    <method name="PlayPause"/>
    <method name="Stop"/>
    <method name="Play"/>
    <method name="Seek"><arg name="Offset" type="x" direction="in"/></method>
    <method name="SetPosition">
      <arg name="TrackId" type="o" direction="in"/>
      <arg name="Position" type="x" direction="in"/>
    </method>
    <method name="OpenUri"><arg name="Uri" type="s" direction="in"/></method>
    <signal name="Seeked"><arg name="Position" type="x"/></signal>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="LoopStatus" type="s" access="readwrite"/>
    <property name="Rate" type="d" access="readwrite"/>
    <property name="Shuffle" type="b" access="readwrite"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="readwrite"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
</node>"""

# Roon's loop values and MPRIS's LoopStatus are the same idea, different words.
LOOP_TO_MPRIS = {"disabled": "None", "loop": "Playlist", "loop_one": "Track"}
MPRIS_TO_LOOP = {v: k for k, v in LOOP_TO_MPRIS.items()}


def _variant(signature, value):
    return (signature, value)


class MprisService(threading.Thread):
    """A MediaPlayer2 for whichever zone the plugin is currently driving.

    One player, not one per zone: MPRIS has no concept of rooms, and a media
    key means "the thing I am listening to". Which zone that is stays the
    plugin's decision, and follows the same active-zone rule as the UI.
    """

    def __init__(self, command, snapshot, log=None):
        super().__init__(daemon=True)
        self._command = command          # (action, arg) -> None
        self._snapshot = snapshot        # () -> zone dict or None
        self._log = log or (lambda *a: None)
        self._conn = None
        self._published = {}
        self._track_serial = 0
        self._track_key = None
        self._stop = threading.Event()
        self.bus_name = ""

    # -- lifecycle ---------------------------------------------------------

    def stop(self):
        self._stop.set()
        try:
            if self._conn:
                self._conn.close()
        except Exception:  # noqa: BLE001
            pass

    def run(self):
        try:
            self._conn = open_dbus_connection(bus="SESSION")
        except Exception as exc:  # noqa: BLE001 - no bus is survivable
            self._log("mpris: no session bus (%r)" % exc)
            return

        if not self._claim_name():
            return

        self._published = self._all_properties()
        while not self._stop.is_set():
            try:
                message = self._conn.receive()
            except Exception:  # noqa: BLE001 - closed on shutdown
                return
            if message.header.message_type is not MessageType.method_call:
                continue
            try:
                self._dispatch(message)
            except Exception as exc:  # noqa: BLE001 - one bad call is not fatal
                self._log("mpris dispatch failed: %r" % exc)

    def _claim_name(self):
        # A second shell on the same session would collide, so fall back to a
        # pid-suffixed name rather than fighting over the plain one.
        for candidate in ("org.mpris.MediaPlayer2.roon",
                          "org.mpris.MediaPlayer2.roon.instance%d" % os.getpid()):
            try:
                reply = self._conn.send_and_get_reply(
                    message_bus.RequestName(candidate, DBusNameFlags.do_not_queue))
            except Exception as exc:  # noqa: BLE001
                self._log("mpris: RequestName failed (%r)" % exc)
                return False
            # 1 = primary owner, 4 = already owner.
            if reply.body and reply.body[0] in (1, 4):
                self.bus_name = candidate
                self._log("mpris: published as %s" % candidate)
                return True
        self._log("mpris: could not claim a bus name")
        return False

    # -- state -------------------------------------------------------------

    def _zone(self):
        try:
            return self._snapshot() or {}
        except Exception:  # noqa: BLE001
            return {}

    def _track_id(self):
        """A stable object path per track, renewed when the track changes.

        Clients key their metadata cache on this, so it has to change with the
        music and hold still while one track plays.
        """
        zone = self._zone()
        key = (zone.get("title", ""), zone.get("album", ""))
        if key != self._track_key:
            self._track_key = key
            self._track_serial += 1
        return TRACK_PREFIX + str(self._track_serial)

    def _metadata(self):
        zone = self._zone()
        if not zone.get("title"):
            return {"mpris:trackid": _variant("o", NO_TRACK)}
        data = {
            "mpris:trackid": _variant("o", self._track_id()),
            "mpris:length": _variant("x", int(zone.get("length", 0)) * 1_000_000),
            "xesam:title": _variant("s", zone.get("title", "")),
            "xesam:album": _variant("s", zone.get("album", "")),
        }
        artist = zone.get("artist", "")
        if artist:
            # Roon gives one string with slashes; xesam:artist is a list.
            data["xesam:artist"] = _variant(
                "as", [a.strip() for a in artist.split("/") if a.strip()])
        art = zone.get("art", "")
        if art:
            data["mpris:artUrl"] = _variant("s", art)
        return data

    def _all_properties(self):
        zone = self._zone()
        state = zone.get("state", "stopped")
        volume = zone.get("_volume_fraction", 0.0)
        return {
            ROOT_IFACE: {
                "CanQuit": _variant("b", False),
                "CanRaise": _variant("b", True),
                "HasTrackList": _variant("b", False),
                "Identity": _variant("s", "Roon"),
                "SupportedUriSchemes": _variant("as", []),
                "SupportedMimeTypes": _variant("as", []),
            },
            PLAYER_IFACE: {
                "PlaybackStatus": _variant(
                    "s", {"playing": "Playing", "loading": "Playing",
                          "paused": "Paused"}.get(state, "Stopped")),
                "LoopStatus": _variant("s", LOOP_TO_MPRIS.get(zone.get("loop", "disabled"), "None")),
                "Rate": _variant("d", 1.0),
                "MinimumRate": _variant("d", 1.0),
                "MaximumRate": _variant("d", 1.0),
                "Shuffle": _variant("b", bool(zone.get("shuffle"))),
                "Metadata": _variant("a{sv}", self._metadata()),
                "Volume": _variant("d", volume),
                "Position": _variant("x", int(zone.get("seek_position", 0)) * 1_000_000),
                "CanGoNext": _variant("b", bool(zone.get("is_next_allowed"))),
                "CanGoPrevious": _variant("b", bool(zone.get("is_previous_allowed"))),
                "CanPlay": _variant("b", bool(zone.get("is_play_allowed") or state == "playing")),
                "CanPause": _variant("b", bool(zone.get("is_pause_allowed"))),
                "CanSeek": _variant("b", bool(zone.get("is_seek_allowed"))),
                "CanControl": _variant("b", bool(zone)),
            },
        }

    def publish_changes(self):
        """Emit PropertiesChanged for whatever actually moved.

        Called on every zone push, which happens about once a second while
        something plays — so this diffs rather than broadcasting, or every
        client on the bus would wake for a seek tick.
        """
        if not self._conn or not self.bus_name:
            return
        current = self._all_properties()
        for iface, values in current.items():
            previous = self._published.get(iface, {})
            changed = {k: v for k, v in values.items()
                       if k != "Position" and previous.get(k) != v}
            if not changed:
                continue
            try:
                self._conn.send(new_signal(
                    DBusAddress(PATH, interface=PROPS_IFACE),
                    "PropertiesChanged", "sa{sv}as", (iface, changed, [])))
            except Exception as exc:  # noqa: BLE001
                self._log("mpris: signal failed (%r)" % exc)
                return
        self._published = current

    # -- dispatch ----------------------------------------------------------

    def _reply(self, message, signature="", body=()):
        self._conn.send(new_method_return(message, signature, body))

    def _dispatch(self, message):
        fields = message.header.fields
        iface = fields.get(HeaderFields.interface, "")
        member = fields.get(HeaderFields.member, "")
        path = fields.get(HeaderFields.path, "")

        if iface == INTROSPECT_IFACE and member == "Introspect":
            return self._reply(message, "s", (INTROSPECTION,))
        if iface == PEER_IFACE:
            if member == "Ping":
                return self._reply(message)
            if member == "GetMachineId":
                return self._reply(message, "s", (self._machine_id(),))
        if path != PATH:
            return self._conn.send(new_error(
                message, "org.freedesktop.DBus.Error.UnknownObject", "s", ("no such object",)))

        if iface == PROPS_IFACE:
            return self._properties(message, member)
        if iface == ROOT_IFACE:
            return self._root_method(message, member)
        if iface == PLAYER_IFACE:
            return self._player_method(message, member)

        self._conn.send(new_error(
            message, "org.freedesktop.DBus.Error.UnknownInterface", "s", (iface,)))

    @staticmethod
    def _machine_id():
        for path in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
            try:
                with open(path, "r", encoding="ascii") as handle:
                    return handle.read().strip()
            except OSError:
                continue
        return "0" * 32

    def _properties(self, message, member):
        props = self._all_properties()
        if member == "Get":
            iface, name = message.body
            value = props.get(iface, {}).get(name)
            if value is None:
                return self._conn.send(new_error(
                    message, "org.freedesktop.DBus.Error.UnknownProperty", "s", (name,)))
            return self._reply(message, "v", (value,))
        if member == "GetAll":
            iface = message.body[0]
            return self._reply(message, "a{sv}", (props.get(iface, {}),))
        if member == "Set":
            iface, name, variant = message.body
            self._set_property(name, variant)
            return self._reply(message)
        self._conn.send(new_error(
            message, "org.freedesktop.DBus.Error.UnknownMethod", "s", (member,)))

    def _set_property(self, name, variant):
        value = variant[1] if isinstance(variant, tuple) and len(variant) == 2 else variant
        if name == "Volume":
            self._command("volume", max(0.0, min(1.0, float(value))) * 100.0)
        elif name == "Shuffle":
            self._command("shuffle", bool(value))
        elif name == "LoopStatus":
            self._command("loop", MPRIS_TO_LOOP.get(str(value), "disabled"))

    def _root_method(self, message, member):
        if member == "Raise":
            self._command("raise", None)
            return self._reply(message)
        if member == "Quit":
            # Refused on purpose: quitting would kill the shell's bridge, and
            # CanQuit already advertises false.
            return self._reply(message)
        self._conn.send(new_error(
            message, "org.freedesktop.DBus.Error.UnknownMethod", "s", (member,)))

    def _player_method(self, message, member):
        simple = {
            "Next": ("next", None),
            "Previous": ("previous", None),
            "Pause": ("pause", None),
            "PlayPause": ("playpause", None),
            "Stop": ("stop", None),
            "Play": ("play", None),
        }
        if member in simple:
            action, arg = simple[member]
            self._command(action, arg)
            return self._reply(message)
        if member == "Seek":
            offset = message.body[0]
            self._command("seek_relative", offset / 1_000_000.0)
            return self._reply(message)
        if member == "SetPosition":
            _track, position = message.body
            self._command("seek_absolute", position / 1_000_000.0)
            return self._reply(message)
        if member == "OpenUri":
            return self._reply(message)
        self._conn.send(new_error(
            message, "org.freedesktop.DBus.Error.UnknownMethod", "s", (member,)))

    def emit_seeked(self, seconds):
        if not self._conn or not self.bus_name:
            return
        try:
            self._conn.send(new_signal(
                DBusAddress(PATH, interface=PLAYER_IFACE),
                "Seeked", "x", (int(seconds * 1_000_000),)))
        except Exception:  # noqa: BLE001
            pass
