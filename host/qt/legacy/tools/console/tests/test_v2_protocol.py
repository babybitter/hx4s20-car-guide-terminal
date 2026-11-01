from pathlib import Path
import os
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from protocol import (COMMANDS, V2_COMMANDS, Session, LineReceiver, line_command,
                      parse_hardware, parse_status, metric_text)
from test_protocol import STATUS

V2_STATUS = STATUS.replace("NAMPIBCFTVWRESQ", "NAMPIBCFTVWRESQHXZDGUJK")


def hardware_line(version=0, count=8, bank=0, error=0, opened=False, active=False,
                  config=0, event=0, metrics=(0xffffffff, 0, 16, 65535, 1)):
    sq = (version << 16) | (error << 8) | (count << 3) | (bank << 2) | (opened << 1) | active
    si, dm, ld, ff, cl = metrics
    return (f"H CFG={config:08X} EV={event:04X} SI={si:08X} DM={dm:08X} "
            f"LD={ld:08X} FF={ff:08X} CL={cl:08X} SQ={sq:08X}")


class V2ProtocolTests(unittest.TestCase):
    def session(self):
        session = Session("effects")
        session.begin("Q", 0)
        session.receive(V2_STATUS)
        return session

    def test_old_q_and_extended_cap_are_compatible(self):
        self.assertEqual(parse_status(STATUS).capabilities, COMMANDS)
        self.assertEqual(parse_status(V2_STATUS).capabilities, COMMANDS | V2_COMMANDS)
        old = Session("effects")
        old.begin("Q", 0); old.receive(STATUS)
        for code in V2_COMMANDS:
            self.assertFalse(old.allowed(code))
        self.assertTrue(all(self.session().allowed(code) for code in V2_COMMANDS))

    def test_h_snapshot_exact_format_and_actual_mapping(self):
        settings = dict(B=3, C=2, F=5, T=1, V=4, E=1, W=1, R=2, X=3,
                        Z=1, D=1, story_active=1, mute=1, modifier=1, underrun=1)
        shifts = dict(B=0, C=2, F=4, T=7, V=9, E=12, W=13, R=14, X=16,
                      Z=18, D=19, story_active=20, mute=21, modifier=22, underrun=23)
        config = sum(value << shifts[key] for key, value in settings.items())
        line = hardware_line(65535, 16, 1, 2, True, True, config, 0xffff)
        self.assertEqual(len(line)+2, 96)
        snapshot = parse_hardware(line+"\r\n")
        self.assertEqual(snapshot.settings, settings)
        self.assertEqual((snapshot.sequence_version, snapshot.sequence_error, snapshot.sequence_count,
                          snapshot.sequence_bank, snapshot.upload_open, snapshot.story_active),
                         (65535, 2, 16, 1, True, True))
        self.assertEqual(snapshot.event_seq, 65535)
        self.assertEqual(metric_text(snapshot.sd_init_ms), "未测量")
        self.assertEqual(metric_text(snapshot.dir_ms), "0 ms")
        self.assertIn("饱和", metric_text(snapshot.firstframe_ms))
        for invalid in (line.lower(), line+" X=1", line.replace("CFG=", "CF="),
                        line.replace("EV=FFFF", "EV=FFFFF"), "ACK H"):
            self.assertIsNone(parse_hardware(invalid))

    def test_each_cfg_bit_and_sequence_flag_has_independent_meaning(self):
        names = {0:"B",2:"C",4:"F",7:"T",9:"V",12:"E",13:"W",14:"R",16:"X",
                 18:"Z",19:"D",20:"story_active",21:"mute",22:"modifier",23:"underrun"}
        for bit, name in names.items():
            h = parse_hardware(hardware_line(config=1<<bit))
            self.assertEqual(h.settings[name], 1)
            self.assertEqual(sum(h.settings.values()), 1)
        self.assertTrue(parse_hardware(hardware_line(active=True)).story_active)
        self.assertFalse(parse_hardware(hardware_line(active=True)).upload_open)

    def test_scalar_and_upload_wire_commands(self):
        for command in ("H", "U", "X0", "X3", "Z0", "Z1", "D0", "D1", "G0", "G1",
                        "J000000FA0000", "J0F19FA983FFF", "K01", "K16"):
            self.assertEqual(line_command(command), (command+"\r\n").encode())
        for command in ("X4", "Z2", "D2", "G2", "K00", "K17", "K1", "J100000FA0000",
                        "J0f19FA983FFF", "J0F39FA983FFF", "J000000000000", "H ", "U1"):
            with self.subTest(command=command), self.assertRaises(ValueError):
                line_command(command)

    def test_h_never_accepts_ack_and_request_matching_remains_strict(self):
        session = self.session()
        session.begin("H", 0)
        with self.assertRaises(ValueError): session.receive("ACK H")
        self.assertIsNone(session.hardware)
        self.assertEqual(session.receive(hardware_line()), "hardware")
        session.begin("X2", 1)
        old_config = session.hardware.config
        self.assertEqual(session.receive("ACK X"), "ack")
        self.assertEqual(session.hardware.config, old_config)
        session.begin("Q", 2)
        with self.assertRaises(ValueError): session.receive(hardware_line())
        session.reset()
        self.assertIsNone(session.hardware)

    def test_j_source_must_fit_real_count_and_h_framing(self):
        session = self.session()  # C=4
        with self.assertRaises(ValueError): session.begin("J0F19FA983FFF", 0)
        session.begin("J000000FA0000", 0)
        self.assertEqual(session.receive("ACK J"), "ack")
        reader = LineReceiver()
        data = (hardware_line()+"\r\n").encode()
        self.assertEqual(reader.feed(data[:43]), [])
        self.assertEqual(reader.feed(data[43:]), [hardware_line()])

    def test_real_v2_rtl_trace_gui_parser_preserves_all_snapshots(self):
        trace = Path(os.environ.get("UART_V2_RTL_TRACE",
            Path(__file__).resolve().parents[3]/".tooling/uart-v2-replies.log"))
        if not trace.exists():
            self.skipTest("Hooke v2 RTL trace not generated; see docs/uart-v2-protocol.md")
        raw = trace.read_bytes()
        expected_lines = raw.decode("ascii").splitlines()
        self.assertEqual(len(expected_lines), 176, "requires the complete passing v2 trace")
        # Exercise the GUI's real byte framer and Session, with split replies.
        # The trace contains replies only: match each Q/H to a read request;
        # do not infer or replay control commands from recorded ACKs.
        receiver, session = LineReceiver(), Session("effects")
        lines = []
        for offset in range(0, len(raw), 7):
            lines.extend(receiver.feed(raw[offset:offset+7]))
        self.assertEqual(lines, expected_lines)
        self.assertFalse(receiver.buffer)
        counts = {"Q": 0, "H": 0}
        h_fields = (("CFG", "config", 8), ("EV", "event_seq", 4),
                    ("SI", "sd_init_ms", 8), ("DM", "dir_ms", 8),
                    ("LD", "preload_ms", 8), ("FF", "firstframe_ms", 8),
                    ("CL", "cache_ms", 8), ("SQ", "sequence", 8))
        for number, line in enumerate(lines, 1):
            code = line.split(" ", 1)[0]
            if code not in counts:
                continue
            with self.subTest(trace_line=number, kind=code):
                counts[code] += 1
                fields = dict(token.split("=", 1) for token in line.split()[1:])
                self.assertEqual(session.begin(code, number), (code+"\r\n").encode("ascii"))
                if code == "Q":
                    snapshot = parse_status(line)
                    self.assertIsNotNone(snapshot)
                    self.assertEqual(session.receive(line), "status")
                    self.assertEqual(session.status, snapshot)
                    self.assertEqual(fields["CAP"], "NAMPIBCFTVWRESQHXZDGUJKOY")
                    self.assertEqual(snapshot.capabilities, COMMANDS | V2_COMMANDS | frozenset("OY"))
                    self.assertTrue(all(session.allowed(c) for c in V2_COMMANDS))
                    rebuilt = (f"Q P={snapshot.page:03d} C={snapshot.count:03d} "
                        f"A={int(snapshot.auto)} READY={int(snapshot.ready)} ERR={snapshot.error:X} "
                        f"R={snapshot.period} VER=1 CAP={fields['CAP']}")
                else:
                    snapshot = parse_hardware(line)
                    self.assertIsNotNone(snapshot)
                    self.assertEqual(session.receive(line), "hardware")
                    self.assertEqual(session.hardware, snapshot)
                    for wire, attribute, width in h_fields:
                        value = getattr(snapshot, attribute)
                        self.assertEqual(value, int(fields[wire], 16), wire)
                        self.assertEqual(f"{value:0{width}X}", fields[wire], wire)
                    rebuilt = "H " + " ".join(f"{wire}={getattr(snapshot, attribute):0{width}X}"
                        for wire, attribute, width in h_fields)
                self.assertEqual(rebuilt, line, "raw fields must round-trip without truncation or clamping")
        self.assertEqual(counts, {"Q": 22, "H": 12})


if __name__ == "__main__": unittest.main()
