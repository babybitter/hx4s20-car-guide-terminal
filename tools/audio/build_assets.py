"""Offline reproducible audio assets. All writes are rooted beside this script."""
import argparse
import array
import csv
import html
import io
import json
import math
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from audio_codec import SAMPLE_RATE, dbfs, decode, encode, read_wav, statistics, write_wav
from audio_package import crc32, extract, pack, render_rom, rom_words, sha256, validate
from bgm_score import CHORDS, MELODY

ROOT = Path(__file__).resolve().parent


def dump_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def gain_normalize(values, target_rms_db, ceiling_db, max_gain_db=60):
    rms = math.sqrt(sum(x * x for x in values) / len(values))
    peak = max(abs(x) for x in values)
    if rms == 0 or peak == 0:
        raise ValueError('Silent source')
    gain = min(32768 * 10 ** (target_rms_db / 20) / rms,
               32768 * 10 ** (ceiling_db / 20) / peak, 10 ** (max_gain_db / 20))
    result = array.array('h', (round(x * gain) for x in values))
    return result, gain


def prepare_speech(raw, settings):
    # Absolute -52dBFS gate only locates endpoints; never gates samples within speech.
    active = [i for i, x in enumerate(raw) if abs(x) >= 80]
    if not active:
        raise ValueError('TTS returned no speech')
    guard = SAMPLE_RATE * 15 // 1000
    start, end = max(0, active[0] - guard), min(len(raw), active[-1] + guard + 1)
    body = raw[start:end]
    mean = sum(body) / len(body)
    values = [x - mean for x in body]
    fade = SAMPLE_RATE * settings['edge_fade_ms'] // 1000
    for i in range(min(fade, len(values) // 2)):
        factor = 0.5 - 0.5 * math.cos(math.pi * i / max(1, fade - 1))
        values[i] *= factor
        values[-1-i] *= factor
    result, gain = gain_normalize(values, settings['speech_active_rms_dbfs'],
                                  settings['speech_peak_ceiling_dbfs'], settings['max_gain_db'])
    processed = array.array('h', [0] * (SAMPLE_RATE * settings['lead_silence_ms'] // 1000))
    processed.extend(result)
    processed.extend([0] * (SAMPLE_RATE * settings['tail_silence_ms'] // 1000))
    info = {'raw_sample_count': len(raw), 'trim_start': start, 'trim_end_exclusive': end,
            'removed_dc': round(mean, 6), 'gain_db': round(20 * math.log10(gain), 6),
            'active_rms_dbfs': statistics(result)['rms_dbfs']}
    return processed, info


def create_bgm(settings):
    # Original eight-bar ambient arrangement, 60 BPM, 4/4, 32.0 seconds exactly.
    # DDS oscillator phases and envelopes are rendered as periodic events on a ring.
    # Tails crossing 32s wrap to the beginning; no hard zero/fade at the loop seam.
    length = 32 * SAMPLE_RATE
    mix = array.array('d', [0.0]) * length
    table = [math.sin(2 * math.pi * i / 4096) for i in range(4096)]
    chords = CHORDS
    melody = MELODY

    def add_note(midi, start, duration, amplitude, pad):
        frames = round(duration * SAMPLE_RATE)
        origin = round(start * SAMPLE_RATE)
        step = round(440 * 2 ** ((midi - 69) / 12) * (1 << 32) / SAMPLE_RATE)
        phase = 0
        for i in range(frames):
            t = i / SAMPLE_RATE
            if pad:
                env = math.sin(math.pi * i / (frames - 1)) ** 2
            else:
                attack = min(1.0, t / 0.035)
                release = min(1.0, (frames - 1 - i) / (0.35 * SAMPLE_RATE))
                env = attack * release * math.exp(-2.5 * t)
            # Band-limited low harmonics, all well below the 8kHz Nyquist limit.
            tone = table[phase >> 20] + 0.12 * table[((phase * 2) & 0xFFFFFFFF) >> 20]
            if not pad:
                tone += 0.035 * table[((phase * 3) & 0xFFFFFFFF) >> 20]
            mix[(origin + i) % length] += amplitude * env * tone
            phase = (phase + step) & 0xFFFFFFFF

    for bar, chord in enumerate(chords):
        for j, note in enumerate(chord):
            add_note(note, 4 * bar - 0.4, 4.8, 0.12 if j == 0 else 0.09, True)
        for note, beat_seconds in melody[bar * 2:bar * 2 + 2]:
            onset = 4 * bar + beat_seconds * 0.8
            add_note(note, onset, 1.8, 0.16, False)
            add_note(note, onset + 0.23, 1.8, 0.035, False)
            add_note(note, onset + 0.46, 1.8, 0.012, False)
    mean = sum(mix) / length
    values = array.array('d', (x - mean for x in mix))
    # Float oscillator amplitude is about 1; express in PCM units before normalizing.
    values = array.array('d', (x * 32768 for x in values))
    pcm, gain = gain_normalize(values, settings['bgm_rms_dbfs'], settings['bgm_peak_ceiling_dbfs'])
    return pcm, {'title': '湖岸微风', 'composition': '本次原创算法编排，未引用曲谱、MIDI、采样或第三方曲调',
                 'bpm': 60, 'bars': 8, 'meter': '4/4', 'duration_seconds': 32,
                 'oscillator': '32bit DDS, 4096-entry sine table, fundamental + soft harmonics',
                 'chords_midi': chords, 'melody_midi_and_bar_seconds': [(n, t * 0.8) for n, t in melody],
                 'loop': 'Periodic event ring; overlapping chord tails and delay taps wrap across seam',
                 'gain_db': round(20 * math.log10(gain), 6)}


def difference_statistics(pcm, lossy):
    error = sum((a - b) ** 2 for a, b in zip(pcm, lossy))
    power = sum(a * a for a in pcm)
    return {'snr_db': round(10 * math.log10(power / error), 3) if error else 120.0,
            'max_abs_error': max(abs(a - b) for a, b in zip(pcm, lossy))}


def create_preview(entries):
    rows = []
    for entry in entries:
        stem = f"{entry['id']:02d}_{entry['key']}"
        title = html.escape(entry.get('text') or entry.get('title', stem))
        rows.append(f'<tr><td>{entry["id"]}</td><td>{title}</td><td>{entry["seconds"]:.3f}s</td>'
                    f'<td><audio controls preload="none" src="../pcm_wav/{stem}.wav"></audio></td>'
                    f'<td><audio controls preload="none" src="../decoded_wav/{stem}.wav"></audio></td></tr>')
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>S19 离线语音试听</title>
<style>body{font:16px system-ui;margin:2rem;background:#f5f7fa;color:#182838}table{border-collapse:collapse}td,th{padding:10px;border-bottom:1px solid #ccd3dc;text-align:left}audio{width:270px}h1{font-size:24px}</style>
<h1>S19 离线素材试听</h1><p>26条短语音 + 32秒原创背景音乐。左列是PCM原版，右列是AUDIO.BIN实际提取并解码的μ-law版。</p>
<p>请重点试听中文字音、1–3秒节奏及μ-law质感。此页面完全离线，不自动播放、不联网。</p>
<p>整套语音：<audio controls preload="none" src="speech_reel_mulaw.wav"></audio>
两轮BGM接缝：<audio controls preload="none" src="bgm_two_loops_mulaw.wav"></audio></p>
<table><tr><th>ID</th><th>文字</th><th>时长</th><th>PCM 16bit</th><th>μ-law解码</th></tr>'''
    (ROOT / 'preview' / 'index.html').write_text(page + ''.join(rows) + '</table></html>\n', encoding='utf-8')


def build():
    manifest_path = ROOT / 'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    entries = manifest['entries']
    ids = [e['id'] for e in entries]
    if ids != list(range(26)) + [31] or manifest['reserved_ids'] != list(range(26, 31)):
        raise ValueError('Fixed ID contract violated')
    for folder in ['pcm_wav', 'mulaw', 'decoded_wav', 'preview', 'reports']:
        (ROOT / folder).mkdir(exist_ok=True)
    provenance = json.loads((ROOT / 'raw_wav' / 'tts_provenance.json').read_text(encoding='utf-8-sig'))
    if (provenance['voice'], provenance['rate'], provenance['volume']) != (
            manifest['tts']['voice'], manifest['tts']['rate'], manifest['tts']['volume']):
        raise ValueError('TTS provenance disagrees with manifest')
    record_map = {r['id']: r for r in provenance['records']}
    assets, report, pcm_map = {}, [], {}
    settings = manifest['processing']
    for entry in entries:
        clip_id = entry['id']
        stem = f"{clip_id:02d}_{entry['key']}"
        if entry['kind'] == 'speech':
            raw_path = ROOT / 'raw_wav' / f'{stem}.wav'
            record = record_map[clip_id]
            if record['text'] != entry['text'] or record['sha256'] != sha256(raw_path.read_bytes()):
                raise ValueError(f'Stale TTS source for ID {clip_id}; regenerate offline TTS')
            pcm, detail = prepare_speech(read_wav(raw_path), settings)
            if not 0.8 <= len(pcm) / SAMPLE_RATE <= 3.0:
                raise ValueError(f'ID {clip_id} duration {len(pcm)/SAMPLE_RATE:.3f}s outside short speech limit')
        else:
            pcm, detail = create_bgm(settings)
        encoded = encode(pcm)
        lossy = decode(encoded)
        assets[clip_id] = encoded
        pcm_map[clip_id] = pcm
        write_wav(ROOT / 'pcm_wav' / f'{stem}.wav', pcm)
        (ROOT / 'mulaw' / f'{stem}.ulaw').write_bytes(encoded)
        item = dict(entry)
        item.update(statistics(pcm))
        item.update({'processing': detail, 'decoded': statistics(lossy), 'lossy_error': difference_statistics(pcm, lossy),
                     'mulaw_crc32': crc32(encoded), 'mulaw_sha256': sha256(encoded)})
        report.append(item)
        print(f"ID {clip_id:02d}: {item['seconds']:.3f}s, peak {item['peak_dbfs']:.2f}dBFS, mu-law SNR {item['lossy_error']['snr_db']:.2f}dB")
    payload, info = pack(assets)
    info['source_manifest_sha256'] = sha256(manifest_path.read_bytes())
    info['tts_provenance_sha256'] = sha256((ROOT / 'raw_wav' / 'tts_provenance.json').read_bytes())
    info['entries'] = report
    (ROOT / 'AUDIO.BIN').write_bytes(payload)
    dump_json(ROOT / 'package_manifest.json', info)
    (ROOT / 'audio_asset_rom.v').write_text(render_rom(info), encoding='ascii')
    (ROOT / 'audio_asset_rom.hex').write_text(''.join(f'{v:08X}\n' for v in rom_words(info)), encoding='ascii')
    (ROOT / 'mulaw_decode_16.hex').write_text(''.join(f'{x & 0xFFFF:04X}\n' for x in decode(bytes(range(256)))), encoding='ascii')
    reel_pcm, reel_lossy = array.array('h'), array.array('h')
    csv_rows = []
    for item in report:
        clip_id = item['id']
        stem = f"{clip_id:02d}_{item['key']}"
        decoded = decode(extract(payload, info, clip_id))
        write_wav(ROOT / 'decoded_wav' / f'{stem}.wav', decoded)
        slot = info['slots'][clip_id]
        if item['kind'] == 'speech':
            start = len(reel_lossy) / SAMPLE_RATE
            reel_pcm.extend(pcm_map[clip_id])
            reel_lossy.extend(decoded)
            reel_pcm.extend([0] * 5600)
            reel_lossy.extend([0] * 5600)
        else:
            start = ''
        csv_rows.append([clip_id, item['key'], item['text'], item['seconds'], start,
                         slot['byte_offset'], slot['sample_count'], slot['storage_bytes']])
    write_wav(ROOT / 'preview' / 'speech_reel_pcm.wav', reel_pcm)
    write_wav(ROOT / 'preview' / 'speech_reel_mulaw.wav', reel_lossy)
    bgm_lossy = decode(extract(payload, info, 31))
    write_wav(ROOT / 'preview' / 'bgm_two_loops_mulaw.wav', bgm_lossy * 2)
    bgm = pcm_map[31]
    seam = array.array('h', bgm_lossy[-2 * SAMPLE_RATE:])
    seam.extend(bgm_lossy[:2 * SAMPLE_RATE])
    write_wav(ROOT / 'preview' / 'bgm_seam_mulaw.wav', seam)
    buf = io.StringIO(newline='')
    writer = csv.writer(buf)
    writer.writerow(['id', 'key', 'text', 'seconds', 'reel_start_seconds', 'byte_offset', 'sample_count', 'storage_bytes'])
    writer.writerows(csv_rows)
    (ROOT / 'preview' / 'playlist.csv').write_text(buf.getvalue(), encoding='utf-8-sig')
    create_preview(report)
    summary = {'speech_count': 26, 'bgm_id': 31, 'bgm_seconds': 32,
               'speech_seconds': round(sum(x['seconds'] for x in report if x['kind'] == 'speech'), 6),
               'speech_min_seconds': min(x['seconds'] for x in report if x['kind'] == 'speech'),
               'speech_max_seconds': max(x['seconds'] for x in report if x['kind'] == 'speech'),
               'package_bytes': len(payload), 'package_mib': round(len(payload) / 1048576, 6),
               'padding_bytes': len(payload) - sum(len(x) for x in assets.values()),
               'crc32': info['crc32'], 'sha256': info['sha256'], 'active_mask': info['active_mask'],
               'bgm_loop_pcm_jump': abs(bgm[0] - bgm[-1]),
               'bgm_loop_mulaw_jump': abs(bgm_lossy[0] - bgm_lossy[-1]),
               'bgm_max_adjacent_pcm_step': max(abs(a - b) for a, b in zip(bgm[1:], bgm)),
               'hardware_status': '未运行TD，未访问串口/TF/Flash；ROM资源与板上声音待父线程验证',
               'listen_status': '客观波形/格式检查；听感由父线程/用户试听确认'}
    dump_json(ROOT / 'reports' / 'build_report.json', summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


def inspect():
    payload = (ROOT / 'AUDIO.BIN').read_bytes()
    info = json.loads((ROOT / 'package_manifest.json').read_text(encoding='utf-8'))
    validate(payload, info)
    print(json.dumps({k: v for k, v in info.items() if k not in ('entries', 'slots')}, ensure_ascii=False, indent=2))


def decode_id(clip_id):
    payload = (ROOT / 'AUDIO.BIN').read_bytes()
    info = json.loads((ROOT / 'package_manifest.json').read_text(encoding='utf-8'))
    audio = decode(extract(payload, info, clip_id))
    path = ROOT / 'preview' / f'extracted_{clip_id:02d}.wav'
    write_wav(path, audio)
    print(path)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['build', 'inspect', 'decode'])
    parser.add_argument('--id', type=int)
    args = parser.parse_args()
    if args.command == 'build':
        build()
    elif args.command == 'inspect':
        inspect()
    elif args.id is None:
        parser.error('decode requires --id')
    else:
        decode_id(args.id)
