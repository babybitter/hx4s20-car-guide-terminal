from pathlib import Path
import json
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from protocol import parse_hardware, parse_status, line_command
from sequence import SequenceUpload, validate_sequence, pack_entry
from test_v2_protocol import V2_STATUS, hardware_line


def document(entries=None):
    if entries is None:
        entries = [dict(source_id=1, title_id=8, dwell_ms=5000, transition=5, cue=0, prompt=False),
                   dict(source_id=2, title_id=128, dwell_ms=1000, transition=7, cue=4, prompt=True)]
    return json.dumps(dict(schema=1, entries=entries))


class SequenceTests(unittest.TestCase):
    def upload(self, text=None):
        return SequenceUpload(text or document(), parse_status(V2_STATUS))

    def begin(self, upload, version=9, bank=0):
        self.assertEqual(upload.next_command(0), "H")
        self.assertIsNone(upload.next_command(0))
        h = hardware_line(version=version, bank=bank)
        upload.receive("hardware", h, parse_hardware(h), .01)

    def submit(self, upload):
        now = 1.0
        sent = []
        while upload.phase == "send":
            command = upload.next_command(now)
            self.assertIsNotNone(command)
            line_command(command)
            self.assertIsNone(upload.next_command(now+1))
            sent.append(command)
            upload.receive("ack", "ACK "+command[0], None, now+.01)
            now += .1
        return sent, now

    def test_full_validation_ranges_types_and_unknown_fields(self):
        self.assertEqual(len(validate_sequence(document(), 4)), 2)
        entries = json.loads(document())["entries"]
        for field, value in (("source_id", 0), ("source_id", 129), ("source_id", True),
                             ("title_id", 0), ("title_id", 129), ("dwell_ms", 999),
                             ("dwell_ms", 60001), ("dwell_ms", 1000.0), ("transition", 8),
                             ("cue", 5), ("prompt", 1), ("prompt", "false")):
            bad = [dict(entries[0]), dict(entries[1])]
            bad[-1][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_sequence(document(bad))
        with self.assertRaises(ValueError): validate_sequence(document(), 1)
        for invalid in ('{"schema":1,"schema":1,"entries":[]}', '['*2000+'0'+']'*2000, document([]),
                        document(entries*9), document().replace('"schema": 1', '"schema": true'),
                        document().replace('"cue": 0', '"cue": NaN'),
                        document().replace('"cue": 0', '"extra": 0, "cue": 0')):
            with self.assertRaises(ValueError): validate_sequence(invalid)

    def test_40bit_known_vectors_and_16_entry_encoding(self):
        low = dict(source_id=1,title_id=1,dwell_ms=1000,transition=0,cue=0,prompt=False)
        high = dict(source_id=128,title_id=128,dwell_ms=60000,transition=7,cue=4,prompt=True)
        self.assertEqual(pack_entry(validate_sequence(document([low]))[0]), 0x0000FA0000)
        self.assertEqual(pack_entry(validate_sequence(document([high]))[0]), 0x19FA983FFF)
        status = parse_status(V2_STATUS.replace("C=004", "C=128"))
        upload = SequenceUpload(document([high]*16), status)
        self.assertEqual(upload.commands[0], "U")
        self.assertEqual(upload.commands[1], "J0019FA983FFF")
        self.assertEqual(upload.commands[-2], "J0F19FA983FFF")
        self.assertEqual(upload.commands[-1], "K16")
        self.assertEqual(len(upload.commands), 18)

    def test_cap_ready_and_complete_validation_before_baseline_h(self):
        for status in (None, parse_status(V2_STATUS.replace("READY=1", "READY=0")),
                       parse_status(V2_STATUS.replace("HXZDGUJK", "H"))):
            with self.assertRaises(ValueError): SequenceUpload(document(), status)
        invalid_last = json.loads(document())["entries"]
        invalid_last[-1]["source_id"] = 5
        with self.assertRaises(ValueError): self.upload(document(invalid_last))

    def test_ack_k_is_pending_until_matching_h_publication(self):
        upload = self.upload()
        self.begin(upload)
        sent, now = self.submit(upload)
        self.assertEqual([cmd[0] for cmd in sent], ["U", "J", "J", "K"])
        self.assertEqual(upload.phase, "commit")
        self.assertEqual(upload.next_command(now), "H")
        old = parse_hardware(hardware_line(version=9, count=8, opened=True))
        upload.receive("hardware", "H", old, now)
        self.assertEqual(upload.phase, "commit")
        self.assertEqual(upload.next_command(now+.2), "H")
        new = parse_hardware(hardware_line(version=10, count=2, bank=1))
        upload.receive("hardware", "H", new, now+.2)
        self.assertEqual(upload.phase, "applied")
        self.assertIsNone(upload.next_command(now+10))

    def test_version_wraparound_is_valid(self):
        upload = self.upload()
        self.begin(upload, 65535, 1)
        _, now = self.submit(upload)
        self.assertEqual(upload.next_command(now), "H")
        upload.receive("hardware", "H", parse_hardware(hardware_line(version=0,count=2,bank=0)), now)
        self.assertEqual(upload.phase, "applied")

    def test_sq_error_wrong_bank_count_or_version_never_claim_applied(self):
        for fields in (dict(version=9,error=1), dict(version=9,error=2), dict(version=9,error=3),
                       dict(version=10,count=2,bank=0), dict(version=10,count=3,bank=1),
                       dict(version=10,count=2,bank=1,opened=True), dict(version=11,count=2,bank=1)):
            with self.subTest(fields=fields):
                upload = self.upload()
                self.begin(upload)
                _, now = self.submit(upload)
                upload.next_command(now)
                upload.receive("hardware", "H", parse_hardware(hardware_line(**fields)), now)
                self.assertFalse(upload.active)
                self.assertNotEqual(upload.phase, "applied")

    def test_rejection_cancel_and_timeout_do_not_replay(self):
        upload = self.upload()
        self.begin(upload)
        self.assertEqual(upload.next_command(1), "U")
        upload.receive("error", "ERR BUSY", None, 1)
        self.assertIsNone(upload.next_command(10))
        upload = self.upload(); self.begin(upload)
        upload.abort("cancel")
        self.assertIsNone(upload.next_command(10))
        upload = self.upload(); self.begin(upload)
        _, now = self.submit(upload)
        self.assertIsNone(upload.next_command(now+6))
        self.assertEqual(upload.phase, "unknown")


if __name__ == "__main__": unittest.main()
