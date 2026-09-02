#!/usr/bin/env python3
"""Behavioural tests for the bridge's pure functions.

The bridge is the largest single thing in this plugin and until now the only
thing standing over it was a structural check that no method was defined
twice. These are the parts with real logic in them and no Roon core required:
text cleaning, album identity, breadcrumb collapsing, and the A-Z index.

Run directly, or through check.sh, which points them at the plugin's venv so
`import roonapi` resolves.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge"))

import lan  # noqa: E402
import roon_bridge as rb  # noqa: E402
import safeio  # noqa: E402


class Initial(unittest.TestCase):
    def test_plain_titles_take_their_first_letter(self):
        self.assertEqual(rb._initial("Laughing Stock"), "L")
        self.assertEqual(rb._initial("tool"), "T")

    def test_numbers_and_symbols_share_one_bucket(self):
        for title in ("8 Miles High", "1492: Conquest of Paradise", "99.9%",
                      "!!!", "…and Justice For All"):
            self.assertEqual(rb._initial(title), "#", title)

    # A rail with separate stops for A, Á and Æ is not an alphabet, and the
    # records behind them would be unreachable from the letters people press.
    def test_accents_fold_into_their_plain_letter(self):
        self.assertEqual(rb._initial("Ágætis byrjun"), "A")
        self.assertEqual(rb._initial("Æther"), "A")
        self.assertEqual(rb._initial("Öksnehallen"), "O")
        self.assertEqual(rb._initial("Björk"), "B")
        # NFKD leaves ligatures and slashed letters whole; Unicode names them.
        self.assertEqual(rb._initial("Ødipus"), "O")
        self.assertEqual(rb._initial("ß-side"), "S")
        self.assertEqual(rb._initial("Œuvre"), "O")

    def test_leading_whitespace_is_stepped_over(self):
        self.assertEqual(rb._initial("   Spirit of Eden"), "S")

    def test_nothing_usable_is_still_a_bucket(self):
        self.assertEqual(rb._initial(""), "#")
        self.assertEqual(rb._initial(None), "#")
        # The one artist in this library whose name is a zalgo emoticon.
        self.assertEqual(rb._initial("ʅ͡͡͡(̸̢̛̼̞̭͋ͅ)̸͚̰͛"), "#")

    def test_roon_markup_is_stripped_before_bucketing(self):
        self.assertEqual(rb._initial("[[14671454|Atrice]]"), "A")


class LetterMarks(unittest.TestCase):
    def marks(self, titles):
        return {m["letter"]: m["index"] for m in rb.letter_marks(titles)}

    def test_each_letter_reports_where_it_starts(self):
        titles = ["Apple", "Avocado", "Banana", "Cherry", "Cherry Two"]
        self.assertEqual(self.marks(titles), {"A": 0, "B": 2, "C": 3})

    def test_numerals_lead_and_claim_only_their_own_run(self):
        titles = ["8 Miles High", "1492", "Apple", "Banana"]
        self.assertEqual(self.marks(titles), {"#": 0, "A": 2, "B": 3})

    # The bug this function exists for. Roon's collation ignores leading
    # articles and punctuation, so a few rows sit nowhere near where their
    # first character says they should. One row at index 11 of 788 took T and
    # sent the rail to the top of the list; guarding that by forcing the marks
    # to climb then locked out every letter below T, leaving eight of them.
    def test_a_stray_early_title_does_not_claim_its_letter(self):
        titles = (["1492", "'Til Tuesday"]
                  + ["A%d" % i for i in range(20)]
                  + ["B%d" % i for i in range(20)]
                  + ["T%d" % i for i in range(20)]
                  + ["U%d" % i for i in range(20)])
        marks = self.marks(titles)
        self.assertEqual(marks["A"], 2)
        self.assertEqual(marks["B"], 22)
        self.assertEqual(marks["T"], 42, "T was claimed by the stray at index 1")
        self.assertEqual(marks["U"], 62)

    # And the letters below the stray must survive it. Bisection dropped five
    # of them against the real library, because a stray sorted among the A's
    # reads as "at or after B" and swallows the probe.
    def test_a_stray_does_not_swallow_the_letters_beneath_it(self):
        titles = (["A0", "The Colour", "A1", "A2", "A3", "A4"]
                  + ["B%d" % i for i in range(10)]
                  + ["C%d" % i for i in range(10)])
        marks = self.marks(titles)
        self.assertEqual(marks["A"], 0)
        self.assertEqual(marks["B"], 6, "B was swallowed by the stray T")
        self.assertEqual(marks["C"], 16)

    # A letter with only a row or two still gets a stop: the run is completed
    # by the letters after it, which also sort "at or after".
    def test_a_letter_with_only_one_row_still_gets_a_stop(self):
        titles = ["A%d" % i for i in range(10)] + ["Xylophone"] + ["Y0", "Y1"]
        marks = self.marks(titles)
        self.assertEqual(marks["X"], 10)
        self.assertEqual(marks["Y"], 11)

    def test_the_last_letter_of_a_level_is_not_lost_to_the_run_length(self):
        titles = ["A%d" % i for i in range(20)] + ["Zebra"]
        self.assertEqual(self.marks(titles)["Z"], 20)

    # The real tail of this library: three Z albums and then a Japanese title,
    # which buckets as # and used to break Z's run at three.
    def test_an_unsortable_row_does_not_break_the_run_it_follows(self):
        titles = (["Y%d" % i for i in range(10)]
                  + ["Zauberberg", "Zenzealia", "Zuckerzeit"]
                  + ["\u30de\u30ea\u30aa\u30ab\u30fc\u30c8"])
        marks = self.marks(titles)
        self.assertEqual(marks["Z"], 10)
        self.assertEqual(marks["Y"], 0)

    def test_unsortable_rows_in_the_middle_do_not_break_a_run(self):
        titles = ["A0", "A1", "!!!", "A2", "A3", "B0", "B1", "B2", "B3"]
        marks = self.marks(titles)
        self.assertEqual(marks["A"], 0)
        self.assertEqual(marks["B"], 5)

    # The numerals still lead, because "#" is the first stop on the rail and
    # the scan for it accepts every row.
    # A stray can also sit at the head of a letter's run, which is how A went
    # missing from a library that is 10% A: the run started on the stray, and
    # the run's first row was being taken as the stop.
    def test_a_stray_at_the_head_of_a_run_does_not_take_the_stop(self):
        titles = (["1492", "The Colour"]
                  + ["A%d" % i for i in range(20)]
                  + ["B%d" % i for i in range(20)])
        marks = self.marks(titles)
        self.assertEqual(marks["A"], 2)
        self.assertEqual(marks["B"], 22)
        self.assertNotIn("T", marks, "the stray claimed a stop of its own")

    def test_the_hash_stop_is_the_top_of_the_level(self):
        titles = ["8 Miles High", "1492", "Apple", "Banana", "Cherry", "Dog"]
        self.assertEqual(self.marks(titles)["#"], 0)

    # A level that starts with letters has no # stop, and an unsortable row
    # further down does not invent one.
    def test_an_unsortable_row_further_down_is_not_a_hash_stop(self):
        titles = ["A0", "A1", "!!!", "A2", "B0", "B1", "B2", "B3"]
        self.assertNotIn("#", self.marks(titles))

    def test_marks_only_ever_climb(self):
        titles = ["Apple", "Banana", "Cherry", "Yak", "Zebra"]
        marks = rb.letter_marks(titles)
        letters = [m["letter"] for m in marks]
        indices = [m["index"] for m in marks]
        self.assertEqual(letters, sorted(letters))
        self.assertEqual(indices, sorted(indices))

    def test_a_letter_with_no_rows_gets_no_mark(self):
        marks = self.marks(["Apple", "Cherry"])
        self.assertNotIn("B", marks)
        self.assertEqual(marks, {"A": 0, "C": 1})

    def test_an_empty_level_has_no_marks(self):
        self.assertEqual(rb.letter_marks([]), [])


class CleanText(unittest.TestCase):
    # Roon puts entity markup in display strings, which is how "[[2345678"
    # ended up on screen while browsing Qobuz.
    def test_entity_markup_is_reduced_to_its_label(self):
        self.assertEqual(rb.clean_text("[[14671454|Atrice]]"), "Atrice")
        self.assertEqual(rb.clean_text("Two [[1|A]] and [[2|B]]"), "Two A and B")

    def test_plain_text_survives_untouched(self):
        self.assertEqual(rb.clean_text("Laughing Stock"), "Laughing Stock")

    def test_missing_text_is_an_empty_string_not_none(self):
        self.assertEqual(rb.clean_text(None), "")

    # The markup is also the only signal distinguishing a row already in the
    # library from one in a streaming catalogue.
    def test_markup_presence_is_the_catalogue_signal(self):
        self.assertTrue(rb.has_link_markup("[[1|Atrice]]", "Album"))
        self.assertFalse(rb.has_link_markup("Atrice", "Album"))


# Both of the following are instance methods that touch no instance state, and
# constructing a real backend would open a socket to a Roon core. A bare
# instance gives them a `self` to be bound to and nothing else.
def backend():
    return object.__new__(rb.RoonBackend)


class AlbumIdentity(unittest.TestCase):
    """One record is one row in the history and the favourites, and both files
    plus the UI have to agree on which rows are the same record."""

    def key(self, **entry):
        return backend()._album_key(entry)

    def test_the_cover_identifies_a_record_when_there_is_one(self):
        a = self.key(album="Please", artist="DJ Plead", art="http://core/img/x")
        b = self.key(album="Please", artist="Someone Else", art="http://core/img/x")
        self.assertEqual(a, b, "the same cover is the same record")

    def test_different_covers_are_different_records(self):
        a = self.key(album="Greatest Hits", art="http://core/img/one")
        b = self.key(album="Greatest Hits", art="http://core/img/two")
        self.assertNotEqual(a, b)

    # Radio streams and local files often arrive without a cover, so the
    # fallback has to hold up on its own.
    def test_without_a_cover_it_falls_back_to_album_and_artist(self):
        a = self.key(album="Spirit of Eden", artist="Talk Talk")
        b = self.key(album="spirit of eden", artist="Talk Talk")
        self.assertEqual(a, b, "case should not fork a record")
        c = self.key(album="Spirit of Eden", artist="Mark Hollis")
        self.assertNotEqual(a, c)

    # A featured guest must not fork the record into two rows.
    def test_only_the_first_credited_artist_counts(self):
        a = self.key(album="Please", artist="DJ Plead")
        b = self.key(album="Please", artist="DJ Plead / Guest")
        self.assertEqual(a, b)


class History(unittest.TestCase):
    """Roon has no history of any kind, so this log is the plugin's own and
    its collapsing rules are the only thing keeping it album-shaped."""

    def normalise(self, entries):
        return backend()._normalise_history(entries)

    def test_plays_of_one_record_collapse_to_a_single_row(self):
        rows = self.normalise([
            {"album": "Please", "artist": "DJ Plead", "art": "a", "at": 10, "tracks": 1},
            {"album": "Please", "artist": "DJ Plead", "art": "a", "at": 20, "tracks": 1},
            {"album": "Please", "artist": "DJ Plead", "art": "a", "at": 30, "tracks": 1},
        ])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["tracks"], 3)
        self.assertEqual(rows[0]["at"], 30, "the row should carry the latest play")

    def test_rows_come_back_newest_first(self):
        rows = self.normalise([
            {"album": "Old", "at": 10, "art": "a"},
            {"album": "New", "at": 99, "art": "b"},
            {"album": "Middle", "at": 50, "art": "c"},
        ])
        self.assertEqual([r["album"] for r in rows], ["New", "Middle", "Old"])

    def test_a_row_missing_its_cover_takes_one_from_a_later_play(self):
        rows = self.normalise([
            {"album": "Please", "artist": "DJ Plead", "art": "", "at": 10},
            {"album": "Please", "artist": "DJ Plead", "art": "cover", "at": 20},
        ])
        self.assertEqual(rows[0]["art"], "cover")

    # The first version of this feature wrote a track-level log; the file on
    # disk has to survive the change to album rows.
    def test_a_track_level_file_from_the_first_version_still_loads(self):
        rows = self.normalise([
            {"title": "Vicarious", "artist": "Tool", "at": 5},
            {"title": "Jambi", "artist": "Tool", "at": 6},
        ])
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["album"], "Jambi", "title stands in for a missing album")

    def test_junk_in_the_file_is_dropped_rather_than_thrown(self):
        rows = self.normalise([None, "nonsense", 42, {"album": "Real", "at": 1}])
        self.assertEqual([r["album"] for r in rows], ["Real"])


class FakeApi:
    def __init__(self, ready=True):
        self.ready = ready
        self.stopped = False

    def stop(self):
        self.stopped = True


class Reconnect(unittest.TestCase):
    """A Roon core that restarts — an update, a reboot, a Nucleus power-cycled
    — used to be permanently fatal to a running plugin: the connect loop
    returned on first success and nothing watched it afterwards."""

    def setUp(self):
        # emit() writes a line of NDJSON to stdout, which is the bridge's whole
        # protocol; captured here so the tests neither print it nor lose it.
        self.sent = []
        self._emit, rb.emit = rb.emit, self.sent.append

    def tearDown(self):
        rb.emit = self._emit

    def kinds(self):
        return [e["type"] for e in self.sent]

    def backend(self, ready=True):
        b = backend()
        b._api = FakeApi(ready=ready)
        b._levels = [{"title": "Albums"}]
        b._roots = [{"title": "Library"}]
        b._queue_subs = {"zone-1"}
        b._queues = {"zone-1": [{"title": "a track"}]}
        b._last_titles = {"zone-1": "a track"}
        b.mpris = None
        b.stopped = False
        return b

    def test_health_follows_the_api(self):
        self.assertTrue(self.backend(ready=True).api_healthy())
        self.assertFalse(self.backend(ready=False).api_healthy())

    def test_health_is_false_with_no_connection_at_all(self):
        b = backend()
        b._api = None
        self.assertFalse(b.api_healthy())

    # Everything the plugin holds is keyed to the session that ended. Browse
    # item_keys are minted per level and are dead the moment the core
    # restarts; keeping any of it would make the next connection lie.
    def test_dropping_lets_go_of_everything_keyed_to_the_session(self):
        b = self.backend()
        api = b._api
        b.drop_connection("gone")
        self.assertTrue(api.stopped, "the old connection was left open")
        self.assertIsNone(b._api)
        self.assertEqual(b._levels, [])
        self.assertEqual(b._roots, [])
        self.assertEqual(b._queue_subs, set())
        self.assertEqual(b._queues, {})
        self.assertEqual(b._last_titles, {})

    def test_dropping_tells_the_ui_before_it_is_asked(self):
        self.backend().drop_connection("Lost the Roon core")
        self.assertIn("zones", self.kinds(), "the old zone list was left on screen")
        self.assertIn("status", self.kinds())
        status = [e for e in self.sent if e["type"] == "status"][0]
        self.assertEqual(status["state"], "error")
        self.assertIn("Lost the Roon core", status["message"])
        self.assertEqual([e for e in self.sent if e["type"] == "zones"][0]["zones"], [])

    # An api that fails to stop must not take the reconnect down with it.
    def test_a_connection_that_will_not_close_is_still_let_go(self):
        b = self.backend()

        def explode():
            raise OSError("socket already gone")

        b._api.stop = explode
        b.drop_connection("gone")
        self.assertIsNone(b._api)

    def test_the_watcher_holds_while_the_core_answers(self):
        b = self.backend(ready=True)
        ticks = []

        def stop_after_three(_seconds):
            ticks.append(1)
            if len(ticks) >= 3:
                b.stopped = True

        original, rb.time.sleep = rb.time.sleep, stop_after_three
        try:
            rb._watch_connection(b, health_interval=0)
        finally:
            rb.time.sleep = original
        self.assertIsNotNone(b._api, "a healthy core was dropped")

    def test_the_watcher_returns_as_soon_as_the_core_stops_answering(self):
        b = self.backend(ready=True)

        def fail_on_first_tick(_seconds):
            b._api.ready = False

        original, rb.time.sleep = rb.time.sleep, fail_on_first_tick
        try:
            rb._watch_connection(b, health_interval=0)
        finally:
            rb.time.sleep = original
        self.assertIsNone(b._api, "the dead connection was kept")
        self.assertIn("status", self.kinds())


class Breadcrumbs(unittest.TestCase):
    # A search wraps an album in a container of the same name, so the stack
    # legitimately holds it twice.
    def test_adjacent_repeats_collapse(self):
        self.assertEqual(rb._dedupe_adjacent(["Library", "Please", "Please"]),
                         ["Library", "Please"])

    def test_non_adjacent_repeats_are_left_alone(self):
        self.assertEqual(rb._dedupe_adjacent(["A", "B", "A"]), ["A", "B", "A"])




class SafeStateIO(unittest.TestCase):
    """The state directory holds an auth token and a listening log, in a
    world-traversable parent. The first version of this got three of four
    wrong: a 0755 directory because makedirs is masked by umask, 0644 files,
    and a predictable temp name with no fsync."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "state.json")

    def test_a_written_file_is_private_at_creation(self):
        safeio.write_json_private(self.path, {"token": "secret"})
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_the_directory_is_really_private(self):
        # os.makedirs(mode=0o700) yields 0755 under the usual 0022 umask.
        nested = os.path.join(self.dir, "deeper")
        safeio.ensure_private_dir(nested)
        self.assertEqual(os.stat(nested).st_mode & 0o777, 0o700)

    def test_it_round_trips(self):
        safeio.write_json_private(self.path, {"a": [1, 2, 3]})
        self.assertEqual(safeio.read_json(self.path), {"a": [1, 2, 3]})

    def test_no_temp_file_is_left_behind(self):
        safeio.write_json_private(self.path, {"a": 1})
        self.assertEqual(os.listdir(self.dir), ["state.json"])

    # A local foothold that plants a symlink must not redirect our read.
    def test_a_symlink_is_refused(self):
        target = os.path.join(self.dir, "real.json")
        io_open = open(target, "w")
        io_open.write('{"a": 1}')
        io_open.close()
        link = os.path.join(self.dir, "link.json")
        os.symlink(target, link)
        with self.assertRaises(safeio.UnsafePath):
            safeio.read_json(link)

    def test_an_oversized_file_is_refused_rather_than_parsed(self):
        with open(self.path, "w") as handle:
            handle.write("[" + ",".join(['"x"'] * 200000) + "]")
        with self.assertRaises(safeio.UnsafePath):
            safeio.read_json(self.path, limit=1024)

    # Hardening the write path does nothing for files an earlier version left
    # behind at 0644, so opening one repairs it.
    def test_reading_repairs_a_file_left_world_readable(self):
        with open(self.path, "w") as handle:
            handle.write('{"a": 1}')
        os.chmod(self.path, 0o644)
        self.assertEqual(safeio.read_json(self.path), {"a": 1})
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_a_missing_or_corrupt_file_gives_the_default(self):
        self.assertEqual(safeio.read_json(self.path, default=[]), [])
        with open(self.path, "w") as handle:
            handle.write("{not json")
        self.assertEqual(safeio.read_json(self.path, default=[]), [])


class LanFallback(unittest.TestCase):
    """Omarchy ships ufw with `default deny incoming`, and Roon's discovery
    reply arrives on a random port, so on a stock install it is dropped."""

    def test_only_directly_attached_subnets_are_swept(self):
        nets = lan.connected_subnets()
        for cidr in nets:
            net = __import__("ipaddress").ip_network(cidr)
            self.assertFalse(net.is_loopback)
            self.assertLessEqual(net.num_addresses, lan.MAX_HOSTS,
                                 "a prefix this large is a port scan")

    # A /16 is 65,000 connections. That is not a fallback.
    def test_an_oversized_prefix_is_not_swept(self):
        self.assertEqual(lan.find_cores(subnets=["10.0.0.0/8"], timeout=0.01), [])

    def test_no_subnets_means_no_sweep(self):
        self.assertEqual(lan.find_cores(subnets=[], timeout=0.01), [])

    def test_a_malformed_subnet_is_ignored(self):
        self.assertEqual(lan.find_cores(subnets=["not-a-network"], timeout=0.01), [])

    # The advice everyone reaches for opens the destination port, and the reply
    # is addressed to a random one, so the hint has to name the source-port form.
    def test_the_firewall_hint_gives_the_rule_that_works(self):
        hint = lan.firewall_hint()
        if not hint:
            self.skipTest("ufw is not active on this machine")
        self.assertIn("proto udp", hint)
        self.assertIn("port %d" % lan.SOOD_PORT, hint)


if __name__ == "__main__":
    unittest.main(verbosity=1)
