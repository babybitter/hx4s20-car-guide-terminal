import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protocol import (parse_audio, Session, LineReceiver, line_command, PERIODS,
                      DEMO_PERIODS, FEATURE_ZOOM_OUT)
from audio_labels import CLIP_TEXT
from test_v2_protocol import V2_STATUS, hardware_line


def audio_line(*, version=1, features=1, clip=255, flags=0x8c, faults=0,
               underruns=0, event=0, position=0):
    return (f"A,{version:02X}{features:02X}{clip:02X}{flags:02X}{faults:02X}"
            f"{underruns:02X}{event:04X}{position:04X}")


class AudioProtocolTests(unittest.TestCase):
    def ready(self, caps=V2_STATUS):
        session = Session("effects")
        session.begin("Q", 0)
        session.receive(caps)
        return session

    def query(self, session, **fields):
        session.begin("AQ", 0)
        self.assertEqual(session.receive(audio_line(**fields)), "audio")
        return session.audio

    def test_full_80bit_vector_and_boundaries(self):
        a = parse_audio("A,011F1FFF69FFFFFFFFFF\r\n")
        self.assertEqual((a.version, a.features, a.clip_id, a.mode), (1, 31, 31, 3))
        self.assertTrue(all((a.assets_ready, a.busy, a.music, a.mute, a.pending, a.stream_fault)))
        self.assertEqual((a.loader_fault, a.zoom_mode, a.player_fault, a.underruns, a.event_seq, a.position_ms),
                         (6, 2, 1, 255, 65535, 65535))
        z = parse_audio(audio_line(flags=0))
        self.assertEqual((z.clip_id, z.mode, z.event_seq, z.position_ms), (255, 0, 0, 0))

    def test_flags_are_independent(self):
        fields = {7: "assets_ready", 6: "busy", 5: "music", 4: "mute", 1: "pending", 0: "stream_fault"}
        for bit, name in fields.items():
            with self.subTest(bit=bit):
                a = parse_audio(audio_line(flags=1 << bit, clip=0 if bit == 6 else 255))
                self.assertTrue(getattr(a, name))
                self.assertEqual(sum(bool(getattr(a, other)) for other in fields.values()), 1)
                self.assertEqual(a.mode, 0)
        for mode in range(4):
            self.assertEqual(parse_audio(audio_line(flags=mode << 2)).mode, mode)

    def test_errors_counters_and_event_position_do_not_overlap(self):
        for load in range(7):
            for zoom in range(3):
                for fault in range(2):
                    a = parse_audio(audio_line(faults=(load << 4) | (zoom << 2) | fault,
                                               underruns=157, event=0xabcd, position=12345))
                    self.assertEqual((a.loader_fault, a.zoom_mode, a.player_fault,
                                      a.underruns, a.event_seq, a.position_ms),
                                     (load, zoom, fault, 157, 0xabcd, 12345))
                    self.assertEqual(a.load_error, a.loader_fault)

    def test_reserved_bit_and_zoom_three_rejected(self):
        for loader in range(7):
            for low in range(16):
                value = parse_audio(audio_line(faults=(loader << 4) | low))
                invalid = bool(low & 2) or (low >> 2) == 3
                self.assertEqual(value is None, invalid, f"detail={loader << 4 | low:02X}")

    def test_zoom_state_does_not_change_feature_capabilities(self):
        s = self.ready()
        for features in (1, 15, 31):
            for zoom in range(3):
                self.query(s, features=features, faults=zoom << 2)
                self.assertEqual(s.audio.zoom_mode, zoom)
                self.assertEqual(s.features, features)
                self.assertEqual(s.allowed("Z2"), bool(features & FEATURE_ZOOM_OUT))
                self.assertEqual(s.audio.player_fault, 0)

    def test_strict_hex_version_length_and_framing(self):
        valid = audio_line()
        bad = (None, 1, b"A,0101FF8C000000000000", "", valid + "0", valid[:-1],
               " " + valid, valid + " ", valid + "\n", valid + "\r", valid + "\r\n\r\n",
               valid.replace("A,", "A "), valid.replace("FF", "ＧＧ"),
               valid.replace("FF", "-1"), valid.replace("FF", "+1"),
               valid.replace("FF", "0x"), valid.replace("FF", "FG"),
               audio_line(version=0), audio_line(version=2))
        for value in bad:
            with self.subTest(value=value):
                self.assertIsNone(parse_audio(value))
        self.assertEqual(parse_audio(valid), parse_audio("A," + valid[2:].lower()))

    def test_clip_and_fault_semantics(self):
        for clip in (*range(26), 31):
            self.assertEqual(parse_audio(audio_line(clip=clip, flags=0x40)).clip_id, clip)
        for clip in (26, 27, 28, 29, 30, 32, 254, 255):
            self.assertIsNone(parse_audio(audio_line(clip=clip, flags=0x40)))
        self.assertIsNone(parse_audio(audio_line(clip=0, flags=0)))
        self.assertIsNone(parse_audio(audio_line(faults=0x70)))
        self.assertIsNone(parse_audio(audio_line(faults=0x02)))

    def test_aq_probe_independent_of_cap_and_audio_feature(self):
        s = Session()
        self.assertFalse(s.allowed("AQ"))
        s.begin("Q", 0)
        s.receive(V2_STATUS.split("CAP=")[0] + "CAP=NQ")
        self.assertFalse(s.allowed("A"))
        self.assertTrue(s.allowed("AQ"))
        self.query(s)
        self.assertTrue(s.allowed("L"))  # Works even in control profile, no CAP L.

    def test_cap_l_does_not_imply_audio(self):
        s = self.ready(V2_STATUS + "L")
        self.assertFalse(s.allowed("L"))
        with self.assertRaises(ValueError):
            s.begin("L3", 0)
        self.query(s, features=0)
        self.assertTrue(s.audio_supported)
        self.assertFalse(s.allowed("L"))

    def test_exact_wire_commands_and_z2_opt_in(self):
        for command in ("AQ", "L0", "L1", "L2", "L3"):
            self.assertEqual(line_command(command), (command + "\r\n").encode())
        for command in ("L", "L4", "L-1", "L00", "L 1", "L１", "l1", "AQ0", "Aq", "AQ\n", "Z2", "Z3"):
            with self.subTest(command=command), self.assertRaises(ValueError):
                line_command(command)
        self.assertEqual(line_command("Z2", features=FEATURE_ZOOM_OUT), b"Z2\r\n")

    def test_known_and_unknown_features_are_not_version_heuristics(self):
        s = self.ready()
        for features, periods, zoom in ((1, PERIODS, False), (15, DEMO_PERIODS, True),
                                       (31, DEMO_PERIODS, True), (0x80, PERIODS, False),
                                       (2, DEMO_PERIODS, False), (8, PERIODS, True)):
            self.query(s, features=features)
            self.assertEqual(s.features, features)
            self.assertEqual(s.periods, periods)
            self.assertEqual(s.allowed("Z2"), zoom)
        s.reset()
        self.assertEqual(s.features, 0)
        self.assertEqual(s.periods, PERIODS)
        self.assertFalse(s.allowed("Z2"))

    def test_session_z2_needs_confirmed_features_and_original_cap(self):
        s = self.ready()
        for features in (None, 1, 7):
            if features is not None:
                self.query(s, features=features)
            with self.assertRaises(ValueError): s.begin("Z2", 0)
        self.query(s, features=15)
        s.begin("Z2", 0)
        s.receive("ACK Z")
        s = self.ready(V2_STATUS.replace("XZD", "XD"))
        self.query(s, features=15)
        with self.assertRaises(ValueError): s.begin("Z2", 0)

    def test_ack_l_does_not_mutate_audio_or_old_q_h(self):
        s = self.ready()
        s.begin("H", 0); s.receive(hardware_line())
        self.query(s)
        before = (s.status, s.hardware, s.audio)
        for mode in range(4):
            s.begin(f"L{mode}", 0)
            self.assertEqual(s.receive("ACK L"), "ack")
            self.assertEqual((s.status, s.hardware, s.audio), before)

    def test_aq_never_accepts_ack_a_or_other_reply(self):
        s = self.ready()
        s.begin("AQ", 0)
        for reply in ("ACK A", "ACK AQ", "ACK L", V2_STATUS, hardware_line(), audio_line(version=2)):
            with self.subTest(reply=reply), self.assertRaises(ValueError): s.receive(reply)
            self.assertIsNone(s.audio)
            self.assertEqual(s.pending, "AQ")
        s.receive(audio_line())
        s.begin("A", 0)
        with self.assertRaises(ValueError): s.receive(audio_line())
        s.receive("ACK A")

    def test_legacy_errors_disable_aq_only_and_can_reprobe(self):
        for error in ("ERR", "ERR SYNTAX", "ERR RANGE", "ERR LENGTH"):
            s = self.ready()
            s.begin("AQ", 0)
            self.assertEqual(s.receive(error), "audio_unsupported")
            self.assertFalse(s.audio_supported)
            self.assertFalse(s.allowed("L"))
            s.begin("N", 0); s.receive("ACK N")
            s.begin("H", 0); s.receive(hardware_line())
            self.query(s)
            self.assertTrue(s.audio_supported)

    def test_transient_aq_errors_do_not_claim_old_firmware(self):
        s = self.ready()
        for error in ("ERR BUSY", "ERR FRAME", "ERR TIMEOUT"):
            self.query(s, features=31)
            s.begin("AQ", 0)
            self.assertEqual(s.receive(error), "error")
            self.assertIsNone(s.audio_supported)
            self.assertIsNone(s.audio)
            self.assertFalse(s.allowed("L"))
            self.assertFalse(s.allowed("Z2"))

    def test_partial_frames_coalescing_and_timeout_are_atomic(self):
        raw = (audio_line() + "\r\n").encode()
        for split in range(len(raw) + 1):
            receiver = LineReceiver()
            self.assertEqual(receiver.feed(raw[:split]) + receiver.feed(raw[split:]), [audio_line()])
        s = self.ready()
        s.begin("AQ", 3)
        self.assertFalse(s.timed_out(3.99))
        self.assertTrue(s.timed_out(4))
        with self.assertRaises(ValueError): s.begin("N", 4)
        s.reset()
        self.assertIsNone(s.audio_supported)

    def test_content_table_matches_frozen_candidate_manifest(self):
        manifest = json.loads((ROOT / "fixtures/audio-content-manifest.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(set(CLIP_TEXT), {e["id"] for e in manifest["entries"]})
        for entry in manifest["entries"]:
            if entry["id"] != 31:
                self.assertEqual(CLIP_TEXT[entry["id"]], entry["text"])

    def test_offline_cli_valid_and_invalid(self):
        command = [sys.executable, "-B", str(ROOT / "audio_cli.py"), "querydecode"]
        result = subprocess.run(command + [audio_line(features=31, faults=0x39)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["features"], 31)
        self.assertEqual(json.loads(result.stdout)["zoom_mode"], 2)
        self.assertEqual(json.loads(result.stdout)["loader_fault"], 3)
        self.assertEqual(json.loads(result.stdout)["player_fault"], 1)
        result = subprocess.run(command, input=(audio_line() + "\r\n").encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["clip_id"], 255)
        result = subprocess.run(command, input=b"\xff", capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        result = subprocess.run(command + [audio_line(version=2)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")


if __name__ == "__main__": unittest.main()
