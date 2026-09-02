#!/usr/bin/env python3
"""The endpoint prober's name matching.

Roon hands the plugin a zone's display name and nothing else — no address, no
identifier the device shares — so pairing a zone with the speaker on the LAN is
name matching, and name matching is the weakest link in the whole feature. It
is also pure, which makes it the part most worth pinning down.

Stdlib only, like the module it tests, so this runs under the system
interpreter without the plugin's venv.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge"))

import endpoints  # noqa: E402


def device(name, host="10.0.0.1", **kw):
    return endpoints.Device(host=host, name=name, **kw)


class MatchDevice(unittest.TestCase):
    def match(self, zone, devices, overrides=None):
        return endpoints.match_device(zone, devices, overrides or {})

    def test_an_exact_name_wins(self):
        wanted = device("Kitchen")
        found = self.match("Kitchen", [device("Bedroom"), wanted])
        self.assertIs(found, wanted)

    # The two real cases from this library: a zone named for the room with the
    # brand appended, and a zone named for the brand alone.
    def test_a_zone_named_for_the_room_finds_the_speaker_in_it(self):
        sonos = device("Media Room")
        found = self.match("Media Room - Sonos", [device("Kitchen"), sonos])
        self.assertIs(found, sonos)

    def test_a_zone_named_for_the_brand_finds_the_model(self):
        wiim = device("WiiM Ultra-114A")
        found = self.match("WIIM", [device("Bedroom"), wiim])
        self.assertIs(found, wiim)

    def test_an_unrelated_name_matches_nothing(self):
        self.assertIsNone(self.match("Study", [device("Kitchen"), device("Garage")]))

    def test_an_empty_zone_name_matches_nothing(self):
        self.assertIsNone(self.match("", [device("Kitchen")]))

    def test_no_devices_matches_nothing(self):
        self.assertIsNone(self.match("Kitchen", []))

    # The override file exists precisely for the names this cannot get right.
    def test_an_override_pins_a_zone_to_an_address(self):
        kitchen = device("Kitchen", host="10.0.0.9")
        found = self.match("Study", [kitchen], {"Study": "10.0.0.9"})
        self.assertIs(found, kitchen)

    def test_an_override_to_an_address_we_have_not_seen_is_still_honoured(self):
        found = self.match("Study", [device("Kitchen")], {"Study": "10.0.0.44"})
        self.assertIsNotNone(found)
        self.assertEqual(found.host, "10.0.0.44")

    # An override must beat a name that would otherwise match, or it is not an
    # override.
    def test_an_override_beats_an_exact_name(self):
        exact = device("Study", host="10.0.0.1")
        pinned = device("Kitchen", host="10.0.0.9")
        found = self.match("Study", [exact, pinned], {"Study": "10.0.0.9"})
        self.assertIs(found, pinned)


if __name__ == "__main__":
    unittest.main(verbosity=1)
