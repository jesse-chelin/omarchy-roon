#!/usr/bin/env python3
"""Ask the audio endpoint what it is actually decoding.

Roon's extension API carries no format information — the transport service
gives text, length and artwork and nothing else, and the queue service gives
less. The devices themselves do know, and most of them will say so over the
local network, so this module asks them directly.

Important: what comes back is the **output** format, not Roon's signal path.
For a RAAT endpoint (WiiM, most Roon Ready gear) Roon sends bit-perfect, so it
matches the source file. For Sonos, Roon transcodes and re-streams, so what the
speaker reports is Roon's transport encoding rather than the file on disk. The
UI labels this "Output" for exactly that reason.

Stdlib only, to keep the bridge's dependency surface at one package.

Run standalone to see what your own network yields:

    python3 endpoints.py discover
    python3 endpoints.py probe
    python3 endpoints.py match "Media Room - Sonos"
"""

from __future__ import annotations

import json
import os
import re
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from xml.etree import ElementTree as ET

import safeio

CONFIG_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "omarchy-roon"
)
OVERRIDE_FILE = os.path.join(CONFIG_DIR, "endpoints.json")

SSDP_ADDR = ("239.255.255.250", 1900)
SSDP_TARGETS = ("urn:schemas-upnp-org:device:MediaRenderer:1",)

HTTP_TIMEOUT = 4
SSDP_TIMEOUT = 4

_UA = {"User-Agent": "omarchy-roon/0.1 UPnP/1.0"}

# MIME to the name a person recognises. Roon and its endpoints between them
# use all of these spellings for the same handful of codecs.
CODECS = {
    "flac": "FLAC", "x-flac": "FLAC",
    "mpeg": "MP3", "mp3": "MP3",
    "aac": "AAC", "mp4": "AAC", "m4a": "AAC",
    "alac": "ALAC", "x-alac": "ALAC",
    "wav": "WAV", "x-wav": "WAV", "wave": "WAV",
    "l16": "PCM", "l24": "PCM", "x-pcm": "PCM", "pcm": "PCM",
    "ogg": "OGG", "vorbis": "OGG", "opus": "Opus",
    "aiff": "AIFF", "x-aiff": "AIFF",
    "dsd": "DSD", "dsf": "DSD",
}


def _codec_name(value: str | None) -> str:
    if not value:
        return ""
    token = str(value).lower()
    if "/" in token:
        token = token.split("/")[-1]
    token = token.split(";")[0].strip()
    return CODECS.get(token, token.upper() if len(token) <= 5 else "")


# These are speakers on someone's network, not a service we control. A device
# that is broken, hostile, or merely streaming will happily answer with more
# bytes than we can hold, so the cap belongs here at the producer rather than in
# whatever parses the result.
MAX_RESPONSE_BYTES = 256 * 1024


def _bounded(response) -> str:
    """Read at most MAX_RESPONSE_BYTES from an untrusted endpoint."""
    raw = response.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ValueError("response exceeded %d bytes" % MAX_RESPONSE_BYTES)
    return raw.decode("utf-8", "replace")


def _http(url: str, timeout=HTTP_TIMEOUT, insecure=False) -> str:
    ctx = ssl._create_unverified_context() if insecure else None
    req = urllib.request.Request(url, headers=_UA)
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as response:
        return _bounded(response)


def _num(value) -> int:
    try:
        return int(float(str(value).strip()))
    except (TypeError, ValueError):
        return 0


def compose(codec="", rate=0, depth=0, channels=0) -> str:
    """Render whatever fields we managed to get, in a stable order."""
    parts = []
    if codec:
        parts.append(codec)
    if rate:
        khz = rate / 1000.0
        parts.append(("%g" % round(khz, 1)) + " kHz")
    if depth:
        parts.append("%d bit" % depth)
    if channels:
        parts.append("%dch" % channels)
    return " · ".join(parts)


# ------------------------------------------------------------------ devices


class Device:
    """A renderer found on the network, plus how to interrogate it."""

    def __init__(self, host, name="", room="", manufacturer="", model="",
                 server="", control_url="", friendly=""):
        self.host = host
        self.name = name or host
        self.friendly = friendly or name
        self.room = room
        self.manufacturer = manufacturer
        self.model = model
        self.server = server
        self.control_url = control_url

    @property
    def kind(self) -> str:
        blob = " ".join((self.manufacturer, self.model, self.server, self.name)).lower()
        if "sonos" in blob:
            return "sonos"
        if "linkplay" in blob or "wiim" in blob or "arylic" in blob:
            return "linkplay"
        if "bluesound" in blob or "bluos" in blob or blob.startswith("nad "):
            return "bluos"
        return "upnp"

    # Names a zone might plausibly be matched against.
    @property
    def aliases(self) -> list[str]:
        return [n for n in (self.room, self.name, self.friendly, self.model) if n]

    def as_dict(self) -> dict:
        return {
            "host": self.host, "name": self.name, "room": self.room,
            "manufacturer": self.manufacturer, "model": self.model,
            "kind": self.kind,
        }

    def __repr__(self):
        return "<Device %s %s (%s)>" % (self.host, self.name, self.kind)


def _text(node, tag) -> str:
    for child in node.iter():
        if child.tag.rsplit("}", 1)[-1] == tag and child.text:
            return child.text.strip()
    return ""


def _parse_description(host: str, location: str, server: str) -> Device | None:
    try:
        xml = _http(location, timeout=HTTP_TIMEOUT)
        root = ET.fromstring(xml)
    except (OSError, ET.ParseError, urllib.error.URLError):
        return None

    control_url = ""
    for service in root.iter():
        if service.tag.rsplit("}", 1)[-1] != "service":
            continue
        if "AVTransport" in _text(service, "serviceType"):
            control_url = urllib.parse.urljoin(location, _text(service, "controlURL"))
            break

    room = _text(root, "roomName")
    friendly = _text(root, "friendlyName")
    return Device(
        host=host,
        name=room or friendly,
        room=room,
        manufacturer=_text(root, "manufacturer"),
        model=_text(root, "modelName"),
        server=server,
        control_url=control_url,
        friendly=friendly,
    )


def discover(timeout=SSDP_TIMEOUT) -> list[Device]:
    """SSDP M-SEARCH for media renderers.

    One mechanism covers every family we support: Sonos, LinkPlay/WiiM, BluOS
    and generic DLNA renderers all answer a MediaRenderer search. A device that
    only advertises over mDNS would need adding here, which is why the override
    file exists.
    """
    responses: dict[str, tuple[str, str]] = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(timeout)
    try:
        for target in SSDP_TARGETS:
            message = "\r\n".join([
                "M-SEARCH * HTTP/1.1",
                "HOST: %s:%d" % SSDP_ADDR,
                'MAN: "ssdp:discover"',
                "MX: 2",
                "ST: %s" % target,
                "", "",
            ]).encode()
            # Twice: the first datagram is routinely lost on a busy wifi segment.
            for _ in range(2):
                try:
                    sock.sendto(message, SSDP_ADDR)
                except OSError:
                    pass
        while True:
            try:
                data, addr = sock.recvfrom(65535)
            except (socket.timeout, OSError):
                break
            text = data.decode("utf-8", "replace")
            location = re.search(r"(?im)^LOCATION:\s*(.+)$", text)
            server = re.search(r"(?im)^SERVER:\s*(.+)$", text)
            if location and addr[0] not in responses:
                responses[addr[0]] = (location.group(1).strip(),
                                      server.group(1).strip() if server else "")
    finally:
        sock.close()

    devices = []
    for host, (location, server) in responses.items():
        device = _parse_description(host, location, server)
        if device:
            devices.append(device)
    return devices


# ------------------------------------------------------------------- probes


def probe_bluos(device: Device) -> dict | None:
    """BluOS (Bluesound, NAD).

    The richest source of any endpoint: /Status hands back a preformatted
    streamFormat such as "FLAC 44100/16/2", so nothing has to be inferred.
    """
    try:
        xml = _http("http://%s:11000/Status" % device.host, timeout=2)
        root = ET.fromstring(xml)
    except (OSError, ET.ParseError, urllib.error.URLError):
        return None

    stream = _text(root, "streamFormat")
    quality = _text(root, "quality")
    if not stream and not quality:
        return None

    codec = ""
    rate = depth = channels = 0
    # e.g. "FLAC 44100/16/2" or "MQA 48000/24/2" or "192 kbps MP3"
    numbers = re.search(r"(\d{4,6})\s*/\s*(\d{1,2})\s*/\s*(\d)", stream or "")
    if numbers:
        rate, depth, channels = (_num(numbers.group(1)), _num(numbers.group(2)),
                                 _num(numbers.group(3)))
    words = re.match(r"\s*([A-Za-z][\w+-]*)", stream or "")
    if words:
        codec = _codec_name(words.group(1)) or words.group(1).upper()

    return {
        "source": "bluos",
        "display": compose(codec, rate, depth, channels) or (stream or quality),
        "codec": codec, "rate": rate, "depth": depth, "channels": channels,
        "raw": stream or quality,
    }


def probe_linkplay(device: Device) -> dict | None:
    """WiiM and the wider LinkPlay family (Arylic, Audio Pro, Dayton).

    Newer firmware is HTTPS-only with a self-signed certificate, so
    verification is skipped — on the LAN, against a device we just discovered.
    Older units answer the same path over plain HTTP.
    """
    for scheme, insecure in (("https", True), ("http", False)):
        url = "%s://%s/httpapi.asp?command=getMetaInfo" % (scheme, device.host)
        try:
            payload = json.loads(_http(url, timeout=3, insecure=insecure))
        except (OSError, ValueError, urllib.error.URLError):
            continue

        meta = payload.get("metaData") or payload
        rate = _num(meta.get("sampleRate"))
        depth = _num(meta.get("bitDepth"))
        if not rate and not depth:
            return None
        return {
            "source": "linkplay",
            "display": compose("", rate, depth, 0),
            "codec": "", "rate": rate, "depth": depth, "channels": 0,
            "raw": json.dumps({k: meta.get(k) for k in ("sampleRate", "bitDepth", "bitRate")}),
        }
    return None


def _didl_from_soap(host: str, control_url: str, action: str) -> str:
    envelope = (
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        '<u:%s xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        "<InstanceID>0</InstanceID></u:%s></s:Body></s:Envelope>" % (action, action)
    )
    request = urllib.request.Request(
        control_url,
        data=envelope.encode(),
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPACTION": '"urn:schemas-upnp-org:service:AVTransport:1#%s"' % action,
            **_UA,
        },
    )
    with urllib.request.urlopen(request, timeout=3) as response:
        return _bounded(response)


def probe_upnp(device: Device) -> dict | None:
    """Sonos and every other DLNA renderer, through one code path.

    DIDL-Lite's <res> element can carry sampleFrequency, bitsPerSample and
    nrAudioChannels alongside the MIME type. Whether it does is up to whatever
    is serving the stream — when Roon is the server it usually supplies only
    protocolInfo, which still gives us the codec.
    """
    control = device.control_url or "http://%s:1400/MediaRenderer/AVTransport/Control" % device.host

    didl = ""
    for action in ("GetPositionInfo", "GetMediaInfo"):
        try:
            body = _didl_from_soap(device.host, control, action)
        except (OSError, urllib.error.URLError, urllib.error.HTTPError):
            continue
        match = re.search(r"<(?:TrackMetaData|CurrentURIMetaData)>(.*?)</", body, re.S)
        if match and match.group(1).strip():
            didl = match.group(1)
            break
    if not didl:
        return None

    for entity, char in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&amp;", "&")):
        didl = didl.replace(entity, char)

    res = re.search(r"<res\b([^>]*)>", didl)
    if not res:
        return None
    attrs = dict(re.findall(r'(\w+)="([^"]*)"', res.group(1)))

    protocol = attrs.get("protocolInfo", "")
    mime = protocol.split(":")[2] if protocol.count(":") >= 2 else ""
    codec = _codec_name(mime)
    rate = _num(attrs.get("sampleFrequency"))
    depth = _num(attrs.get("bitsPerSample"))
    channels = _num(attrs.get("nrAudioChannels"))

    display = compose(codec, rate, depth, channels)
    if not display:
        return None
    return {
        "source": "sonos" if device.kind == "sonos" else "upnp",
        "display": display,
        "codec": codec, "rate": rate, "depth": depth, "channels": channels,
        "raw": protocol,
    }


# Ordered by how much each yields, so a device that answers two of them
# reports the better one.
PROBES = {
    "bluos": (probe_bluos, probe_upnp),
    "linkplay": (probe_linkplay,),
    "sonos": (probe_upnp,),
    "upnp": (probe_bluos, probe_linkplay, probe_upnp),
}


def probe(device: Device) -> dict | None:
    for attempt in PROBES.get(device.kind, (probe_upnp,)):
        try:
            result = attempt(device)
        except Exception:  # noqa: BLE001 - a probe must never take the bridge down
            continue
        if result:
            result["device"] = device.name
            result["host"] = device.host
            return result
    return None


# ------------------------------------------------------------------ matching


def _normalise(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())


def load_overrides() -> dict:
    """Manual zone-name to host map, for anything discovery cannot place."""
    try:
        data = safeio.read_json(OVERRIDE_FILE, default={})
    except safeio.UnsafePath:
        return {}
    return data if isinstance(data, dict) else {}


def match_device(zone_name: str, devices: list[Device], overrides: dict | None = None):
    """Pair a Roon zone with a discovered device.

    Roon hands us a display name and nothing else — no address, no identifier
    the device shares. So this is name matching, and name matching is the
    weakest link in the whole feature: "Media Room - Sonos" has to find the
    Sonos whose roomName is "Media Room", and the zone called "WIIM" has to
    find "WiiM Ultra-114A". Exact, then containment, then longest common
    prefix, and an override file for whatever still lands wrong.
    """
    overrides = overrides if overrides is not None else load_overrides()
    pinned = overrides.get(zone_name)
    if pinned:
        for device in devices:
            if device.host == pinned:
                return device
        return Device(host=pinned, name=zone_name)

    target = _normalise(zone_name)
    if not target:
        return None

    best, best_score = None, 0
    for device in devices:
        for alias in device.aliases:
            candidate = _normalise(alias)
            if not candidate:
                continue
            if candidate == target:
                return device
            if candidate in target or target in candidate:
                score = min(len(candidate), len(target)) + 10
            else:
                shared = 0
                for a, b in zip(candidate, target):
                    if a != b:
                        break
                    shared += 1
                score = shared if shared >= 4 else 0
            if score > best_score:
                best, best_score = device, score
    return best


# ---------------------------------------------------------------------- cli


def _main(argv):
    command = argv[1] if len(argv) > 1 else "probe"
    devices = discover()

    if command == "discover":
        print("%d device(s)" % len(devices))
        for device in devices:
            print("  %-16s %-28s kind=%-9s room=%r model=%r"
                  % (device.host, device.name, device.kind, device.room, device.model))
        return 0

    if command == "match":
        zone = argv[2] if len(argv) > 2 else ""
        device = match_device(zone, devices)
        print("zone %r -> %r" % (zone, device))
        if device:
            print("  probe:", json.dumps(probe(device), indent=2))
        return 0

    for device in devices:
        print("%-16s %-28s %-9s -> %s"
              % (device.host, device.name, device.kind,
                 json.dumps(probe(device)) if probe(device) else "(nothing)"))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
