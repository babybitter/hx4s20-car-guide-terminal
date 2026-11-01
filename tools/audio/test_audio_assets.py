"""Codec, adversarial format, generated audio and synchronous ROM checks."""
import array
import copy
import io
import json
import math
import re
import shutil
import subprocess
import sys
import unittest
import warnings
from pathlib import Path

sys.dont_write_bytecode = True
from audio_codec import decode, decode_sample, encode, encode_sample, pcm_bytes, read_wav, statistics
from audio_package import LIMIT, crc32, extract, pack, render_rom, rom_words, sha256, validate

ROOT = Path(__file__).resolve().parent


class CodecTests(unittest.TestCase):
    def test_known_decodes(self):
        expected = {0xFF: 0, 0x7F: 0, 0xFE: 8, 0x7E: -8, 0x80: 32124, 0x00: -32124,
                    0xD5: 716, 0x55: -716, 0xAA: 5372, 0x2A: -5372}
        for code, value in expected.items():
            self.assertEqual(decode_sample(code), value)

    def test_encoder_extremes_and_silence(self):
        self.assertEqual(encode([-32768, -1, 0, 1, 32767]), bytes([0, 0x7E, 0xFF, 0xFF, 0x80]))
        self.assertEqual(encode([0] * 512), b'\xff' * 512)

    def test_exhaustive_decode_roundtrip(self):
        for code in range(256):
            self.assertEqual(encode_sample(decode_sample(code)), 0xFF if code == 0x7F else code)

    def test_monotonic_and_bounded_quantization(self):
        previous = -32769
        for sample in range(-32768, 32768):
            decoded = decode_sample(encode_sample(sample))
            self.assertGreaterEqual(decoded, previous)
            self.assertLessEqual(abs(sample - decoded), 644)
            previous = decoded

    def test_audioop_independent_reference_all_inputs(self):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', DeprecationWarning)
            try:
                import audioop
            except ImportError:
                self.skipTest('Optional Python<=3.12 audioop unavailable; primary codec has no dependency')
        pcm = pcm_bytes(range(-32768, 32768))
        self.assertEqual(encode(range(-32768, 32768)), audioop.lin2ulaw(pcm, 2))
        self.assertEqual(pcm_bytes(decode(bytes(range(256)))), audioop.ulaw2lin(bytes(range(256)), 2))

    def test_invalid_values(self):
        for value in [-32769, 32768]:
            with self.assertRaises(ValueError):
                encode_sample(value)
        for value in [-1, 256]:
            with self.assertRaises(ValueError):
                decode_sample(value)


class FormatTests(unittest.TestCase):
    def setUp(self):
        self.clips = {0: b'\xff\x80\x00', 7: bytes(range(256)) * 2, 31: b'\xfe' * 513}
        self.payload, self.info = pack(self.clips)

    def test_flat_layout_alignment_and_exact_extract(self):
        self.assertEqual(len(self.payload), 2048)
        self.assertEqual(self.payload[:3], self.clips[0])
        self.assertEqual(self.info['slots'][0]['byte_offset'], 0)
        self.assertEqual(self.info['slots'][7]['byte_offset'], 512)
        self.assertEqual(self.info['slots'][31]['byte_offset'], 1024)
        for clip_id, clip in self.clips.items():
            self.assertEqual(extract(self.payload, self.info, clip_id), clip)
        self.assertEqual(self.payload[3:512], b'\xff' * 509)

    def test_precise_length_rejects_truncation_and_trailing_bytes(self):
        for data in [self.payload[:-1], self.payload[:-512], self.payload + b'\xff', self.payload + b'\xff' * 512]:
            with self.assertRaises(ValueError):
                validate(data, self.info)

    def test_corruption_rejected(self):
        for position in [0, 511, 512, 2047]:
            data = bytearray(self.payload)
            data[position] ^= 1
            with self.assertRaises(ValueError):
                validate(bytes(data), self.info)

    def test_padding_checked_even_if_whole_crc_recomputed(self):
        data = bytearray(self.payload)
        data[100] = 0
        info = copy.deepcopy(self.info)
        info['crc32'], info['sha256'] = crc32(data), sha256(data)
        with self.assertRaises(ValueError):
            validate(bytes(data), info)

    def test_bad_offsets_counts_order_and_mask(self):
        changes = [(0, 'byte_offset', 512), (7, 'byte_offset', 513), (7, 'byte_offset', 0),
                   (0, 'sample_count', -1), (0, 'sample_count', LIMIT), (7, 'storage_bytes', 1024),
                   (1, 'byte_offset', 512), (0, 'id', 1), (31, 'sample_count', 4096)]
        for slot, field, value in changes:
            info = copy.deepcopy(self.info)
            info['slots'][slot][field] = value
            with self.subTest(slot=slot, field=field), self.assertRaises(ValueError):
                validate(self.payload, info)
        info = copy.deepcopy(self.info)
        info['active_mask'] = 'FFFFFFFF'
        with self.assertRaises(ValueError):
            validate(self.payload, info)

    def test_reserved_and_out_of_range_ids(self):
        for clip_id in [1, -1, 32, True]:
            with self.assertRaises(ValueError):
                extract(self.payload, self.info, clip_id)

    def test_pack_empty_bad_ids_and_limit(self):
        for clips in [{}, {32: b'a'}, {-1: b'a'}, {0: b''}, {True: b'a'}, {0: b'a' * (LIMIT - 1)}]:
            with self.assertRaises(ValueError):
                pack(clips)
        payload, info = pack({31: b'\xff' * (LIMIT - 512)})
        self.assertEqual(len(payload), LIMIT - 512)
        self.assertTrue(validate(payload, info))

    def test_crc_standard_check_and_streaming(self):
        import zlib
        self.assertEqual(crc32(b'123456789'), 'CBF43926')
        state = 0
        for block in range(0, len(self.payload), 512):
            state = zlib.crc32(self.payload[block:block + 512], state)
        self.assertEqual(f'{state:08X}', self.info['crc32'])


class GeneratedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.payload = (ROOT / 'AUDIO.BIN').read_bytes()
        cls.info = json.loads((ROOT / 'package_manifest.json').read_text(encoding='utf-8'))
        cls.manifest = json.loads((ROOT / 'manifest.json').read_text(encoding='utf-8'))

    def test_whole_package_and_fixed_ids(self):
        self.assertTrue(validate(self.payload, self.info))
        self.assertEqual(self.info['active_mask'], '83FFFFFF')
        self.assertEqual([e['id'] for e in self.info['entries']], list(range(26)) + [31])
        self.assertEqual(self.info['source_manifest_sha256'], sha256((ROOT / 'manifest.json').read_bytes()))
        for clip_id in range(26, 31):
            self.assertEqual(self.info['slots'][clip_id]['sample_count'], 0)

    def test_wav_codec_and_individual_files_match_package(self):
        for entry in self.info['entries']:
            stem = f"{entry['id']:02d}_{entry['key']}"
            pcm = read_wav(ROOT / 'pcm_wav' / f'{stem}.wav')
            ulaw = (ROOT / 'mulaw' / f'{stem}.ulaw').read_bytes()
            actual = extract(self.payload, self.info, entry['id'])
            self.assertEqual(encode(pcm), ulaw)
            self.assertEqual(ulaw, actual)
            self.assertEqual(decode(actual), read_wav(ROOT / 'decoded_wav' / f'{stem}.wav'))
            self.assertEqual(len(pcm), self.info['slots'][entry['id']]['sample_count'])

    def test_speech_duration_silence_peak_and_quality(self):
        for entry in self.info['entries']:
            if entry['kind'] != 'speech':
                continue
            pcm = read_wav(ROOT / 'pcm_wav' / f"{entry['id']:02d}_{entry['key']}.wav")
            self.assertGreaterEqual(len(pcm), 16000)
            self.assertLessEqual(len(pcm), 48000)
            self.assertEqual(pcm[:960], array.array('h', [0] * 960))
            self.assertEqual(pcm[-1600:], array.array('h', [0] * 1600))
            self.assertLessEqual(max(abs(x) for x in pcm), math.ceil(32768 * 10 ** (-3 / 20)))
            self.assertEqual(statistics(pcm)['clip_count'], 0)
            self.assertGreater(entry['lossy_error']['snr_db'], 34)

    def test_bgm_exact_blocks_peak_and_loop(self):
        slot = self.info['slots'][31]
        self.assertEqual(slot['sample_count'], 512000)
        self.assertEqual(slot['storage_bytes'], 1000 * 512)
        pcm = read_wav(ROOT / 'pcm_wav' / '31_idle_bgm.wav')
        decoded = read_wav(ROOT / 'decoded_wav' / '31_idle_bgm.wav')
        self.assertLessEqual(max(abs(x) for x in pcm), math.ceil(32768 * 10 ** (-12 / 20)))
        self.assertAlmostEqual(statistics(pcm)['rms_dbfs'], -27.0, delta=0.05)
        for data in [pcm, decoded]:
            self.assertLessEqual(abs(data[0] - data[-1]), 256)
            self.assertLess(abs(data[0] - data[-1]), max(abs(a - b) for a, b in zip(data[1:], data)))
        self.assertEqual(read_wav(ROOT / 'preview' / 'bgm_two_loops_mulaw.wav'), decoded * 2)

    def test_rom_text_and_hex_exactly_match_offsets(self):
        text = (ROOT / 'audio_asset_rom.v').read_text(encoding='ascii')
        self.assertEqual(text, render_rom(self.info))
        pairs = re.findall(r"rom\[\s*(\d+)\] = 16'h([0-9A-F]{4})", text)
        self.assertEqual([int(a) for a, _ in pairs], list(range(128)))
        halves = [int(v, 16) for _, v in pairs]
        self.assertEqual([halves[i] | halves[i+1]<<16 for i in range(0,128,2)], rom_words(self.info))
        self.assertEqual([int(x, 16) for x in (ROOT / 'audio_asset_rom.hex').read_text().split()], rom_words(self.info))
        self.assertEqual([int(x, 16) for x in (ROOT / 'mulaw_decode_16.hex').read_text().split()],
                         [x & 65535 for x in decode(bytes(range(256)))])

    def test_verilog_synchronous_two_record_reads(self):
        iverilog, vvp = shutil.which('iverilog'), shutil.which('vvp')
        if not iverilog or not vvp:
            self.skipTest('Optional Icarus Verilog not installed; ROM content still validated in Python')
        words = [part for word in rom_words(self.info) for part in (word & 65535, word >> 16)]
        init = '\n'.join(f"expected[{i}] = 16'h{v:04X};" for i, v in enumerate(words))
        bench = f'''`timescale 1ns/1ps
module tb;
reg clk=0; always #5 clk=~clk;
reg [6:0] addr=0; wire [15:0] q; wire [31:0] package_bytes, package_crc32, active_mask;
reg [15:0] expected[0:127]; reg [15:0] held; integer i;
audio_asset_rom dut(clk,addr,q,package_bytes,package_crc32,active_mask);
initial begin
{init}
#1;
if(package_bytes !== 32'd{self.info['byte_count']} || package_crc32 !== 32'h{self.info['crc32']} || active_mask !== 32'h83FFFFFF) $fatal(1,"constant mismatch");
@(posedge clk); #1;
for(i=0;i<128;i=i+1) begin
  @(negedge clk); held=q; addr=i;
  #1; if(q !== held) $fatal(1,"asynchronous read");
  @(posedge clk); #1;
  if(q !== expected[i]) $fatal(1,"ROM address %0d mismatch",i);
end
$display("PASS: 128 synchronous halfword reads, offsets/counts/constants and hold timing");
$finish;
end
endmodule
'''
        bench_path = ROOT / 'reports' / 'tb_audio_asset_rom.v'
        executable = ROOT / 'reports' / 'tb_audio_asset_rom.vvp'
        bench_path.write_text(bench, encoding='ascii')
        compile_result = subprocess.run([iverilog, '-g2012', '-s', 'tb', '-o', str(executable),
                                         str(ROOT / 'audio_asset_rom.v'), str(bench_path)],
                                        capture_output=True, text=True, cwd=ROOT, timeout=30)
        self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
        run = subprocess.run([vvp, str(executable)], capture_output=True, text=True, cwd=ROOT, timeout=30)
        (ROOT / 'reports' / 'rom_simulation.log').write_text(compile_result.stdout + compile_result.stderr + run.stdout + run.stderr, encoding='utf-8')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('PASS: 128 synchronous halfword reads', run.stdout)


if __name__ == '__main__':
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    log = output.getvalue()
    print(log)
    (ROOT / 'reports').mkdir(exist_ok=True)
    (ROOT / 'reports' / 'tests.log').write_text(log, encoding='utf-8')
    (ROOT / 'reports' / 'test_summary.json').write_text(json.dumps(
        {'run': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
         'skipped': len(result.skipped), 'success': result.wasSuccessful()}, indent=2) + '\n', encoding='utf-8')
    sys.exit(0 if result.wasSuccessful() else 1)
