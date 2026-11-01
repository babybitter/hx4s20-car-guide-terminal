"""Original score shared by synthesis and offline note-color metadata export."""
CHORDS = [
    [48, 55, 59, 62, 64], [45, 52, 55, 59, 60],
    [41, 48, 52, 55, 57], [43, 50, 55, 57, 62],
    [40, 47, 50, 55, 59], [41, 48, 52, 57, 60],
    [38, 45, 48, 52, 57], [43, 50, 55, 57, 62],
]
# Original timing units; synthesis multiplies bar-relative times by 0.8.
MELODY = [(72, 0.5), (76, 2.5), (71, 0.75), (67, 3.0),
          (69, 0.5), (72, 2.75), (74, 1.0), (69, 3.0),
          (71, 0.5), (67, 2.5), (72, 1.0), (76, 3.0),
          (69, 0.75), (65, 2.75), (67, 0.5), (74, 2.5)]


def melody_events():
    events = []
    names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
    for i, (midi, time) in enumerate(MELODY):
        start = round((4 * (i // 2) + time * 0.8) * 16000)
        hz = 440 * 2 ** ((midi - 69) / 12)
        step = round(hz * (1 << 32) / 16000)
        events.append({'event': i, 'midi_note': midi, 'note_name': names[midi % 12] + str(midi // 12 - 1),
                       'pitch_class': midi % 12, 'nominal_hz': hz, 'dds_step_u32': step,
                       'dds_hz': step * 16000 / (1 << 32), 'start_sample': start,
                       'duration_samples': 28800, 'end_sample_exclusive': start + 28800,
                       'start_seconds': start / 16000})
    for i, event in enumerate(events):
        # Monophonic color policy: newest note wins, with actual release-end/rest.
        # This does not pretend to identify the concurrent chords/echoes.
        next_start = events[i + 1]['start_sample'] if i + 1 < len(events) else 512000
        event['color_end_sample_exclusive'] = min(event['end_sample_exclusive'], next_start)
    return events
