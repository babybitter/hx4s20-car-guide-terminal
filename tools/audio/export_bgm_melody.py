"""Export original score timing; never estimates notes from polyphonic audio."""
import csv
import hashlib
import json
import sys
from pathlib import Path
sys.dont_write_bytecode = True
from bgm_score import melody_events

ROOT = Path(__file__).resolve().parent


def main():
    events = melody_events()
    metadata = {
        'source': '原创生成器共用bgm_score.py；编曲时间表，不是实时音符识别',
        'audio_id': 31, 'sample_rate': 16000, 'loop_sample_count': 512000,
        'audio_bin_sha256': hashlib.sha256((ROOT / 'AUDIO.BIN').read_bytes()).hexdigest(),
        'pcm_bgm_sha256': hashlib.sha256((ROOT / 'pcm_wav/31_idle_bgm.wav').read_bytes()).hexdigest(),
        'color_policy': '跟随BGM实际sample_index；start<=index<color_end时使用对应pitch_class。重叠尾音取最新主旋律音；空档为休止。BGM暂停位置冻结；切到语音时使用频带颜色。',
        'excluded': '和弦、0.23/0.46秒回声及其他声部不在主旋律单色表内；原音持续1.8秒，允许声学重叠。',
        'rom_words': '32x32，偶地址={midi[6:0],5b0,start_sample[19:0]}，奇地址={12b0,color_end_sample_exclusive[19:0]}；音高类别=midi%12。只表示预先已知编曲。',
        'events': events,
    }
    (ROOT / 'bgm_melody.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    with (ROOT / 'bgm_melody.csv').open('w', newline='', encoding='utf-8-sig') as out:
        writer = csv.DictWriter(out, fieldnames=list(events[0]))
        writer.writeheader()
        writer.writerows(events)
    words = [word for event in events for word in [event['midi_note'] << 25 | event['start_sample'], event['color_end_sample_exclusive']]]
    (ROOT / 'bgm_melody.hex').write_text(''.join(f'{word:08X}\n' for word in words), encoding='ascii')
    lines = ['// Original known score, NOT real-time note detection. 16 events x 2 words.',
             '// Even address: {midi[6:0],5\'b0,start[19:0]}; odd: {12\'b0,end_exclusive[19:0]}.',
             'module bgm_melody_rom(input wire clk, input wire [4:0] addr, output reg [31:0] q);',
             '  reg [31:0] rom [0:31];', '  initial begin']
    lines += [f"    rom[{i}] = 32'h{word:08X};" for i, word in enumerate(words)]
    lines += ['  end', '  always @(posedge clk) q <= rom[addr];', 'endmodule', '']
    (ROOT / 'bgm_melody_rom.v').write_text('\n'.join(lines), encoding='ascii')
    print('Exported 16 original melody events, CSV/JSON and optional synchronous color ROM.')


if __name__ == '__main__':
    main()
