"""Real Qt widgets, isolated snapshots, no physical serial access."""
import json
import os
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'legacy/tools/console'))
sys.dont_write_bytecode = True

from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
from PIL import Image
from app.ui import MainWindow
from app.theme import STYLESHEET, configure_fonts
from protocol import parse_status, parse_hardware, parse_audio
from local_preview import PreviewResult

CAPS = 'NAMPIBCFTVWRESQHXZDGUJKOY'
Q = f'Q P=001 C=008 A=0 READY=1 ERR=0 R=1 VER=1 CAP={CAPS}'
H = 'H CFG=00011000 EV=0001 SI=FFFFFFFF DM=00000000 LD=00000001 FF=00000002 CL=00000000 SQ=00000040'


def audio_snapshot(features=0x1f):
    value = (1 << 72) | (features << 64) | (255 << 56) | (0x80 << 48) | (8 << 40)
    return parse_audio(f'A,{value:020X}')


class QtWindowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        configure_fonts()
        cls.app.setStyle('Fusion')
        cls.app.setStyleSheet(STYLESHEET)
        cls.app.setQuitOnLastWindowClosed(False)

    def setUp(self):
        self.serial_guard = patch('serial.Serial', side_effect=AssertionError('No physical serial allowed'))
        self.port_guard = patch('serial.tools.list_ports.comports', side_effect=AssertionError('No port enumeration in demo'))
        self.serial_guard.start()
        self.port_guard.start()
        self.window = MainWindow(ROOT, demo=True)
        self.window.motion.setChecked(False)
        self.window.show()
        self.pump(25)

    def tearDown(self):
        self.window.subtitle_timer.stop()
        self.window.close()
        self.window.pool.waitForDone(5000)
        self.pump(20)
        self.assertFalse(self.window.thread.isRunning(), 'Qt serial worker must stop on window close')
        self.window.deleteLater()
        self.pump(20)
        self.serial_guard.stop()
        self.port_guard.stop()

    @classmethod
    def pump(cls, milliseconds=30):
        QTest.qWait(milliseconds)
        cls.app.processEvents()

    def wait_for(self, condition, timeout=10.0):
        deadline = time.monotonic() + timeout
        while not condition() and time.monotonic() < deadline:
            self.pump(15)
        self.assertTrue(condition(), 'Timed out waiting for a Qt/background result')

    def inject_state(self, *, audio=None, profile='effects', caps=CAPS):
        # Only presentation state is injected; BackendWorker has no open port.
        self.window.demo = False
        self.window.on_event({'kind':'connection', 'connected':True, 'text':'TEST SNAPSHOT — no hardware'})
        self.window.on_event({'kind':'state', 'status':parse_status(Q.replace(CAPS, caps)),
            'hardware':parse_hardware(H) if 'H' in caps else None,
            'audio':audio, 'audio_supported':audio is not None, 'profile':profile})

    def test_seven_pages_and_offline_unknown_state(self):
        self.assertEqual(self.window.stack.count(), 7)
        self.assertEqual(self.window.nav.count(), 7)
        for index in range(7):
            self.window.nav.setCurrentRow(index)
            self.assertEqual(self.window.stack.currentIndex(), index)
            self.assertEqual(self.window.page_heading.text(), self.window.page_titles[index])
        self.assertIsNone(self.window.session.status)
        self.assertIsNone(self.window.session.hardware)
        self.assertFalse(self.window.connect_button.isEnabled())
        self.assertTrue(all(not w.isEnabled() for w, _ in self.window.actions))
        self.assertTrue(all(not w.isEnabled() for w in self.window.controls.values()))
        self.assertTrue(all(not w.isEnabled() for w in self.window.preset_buttons.values()))
        requests=[]
        self.window.request.connect(requests.append)
        self.window.dispatch({'action':'command','command':'N'})
        self.assertEqual(requests, [])
        self.assertIn('预览', self.window.message.text())

    def test_requested_values_never_replace_actual_readback(self):
        self.inject_state()
        old_actual = {k:v.text() for k,v in self.window.actual_labels.items()}
        self.window.on_event({'kind':'requested','values':{'X':0,'E':1,'T':3,'V':4}})
        for key, value in {'X':0,'E':1,'T':3,'V':4}.items():
            self.assertEqual(self.window.controls[key].currentIndex(), value)
        self.assertEqual(old_actual, {k:v.text() for k,v in self.window.actual_labels.items()})

    def test_capability_gate_and_s19_dynamic_periods_and_zoom(self):
        self.inject_state()
        self.assertEqual(self.window.controls['Z'].count(), 2)
        self.assertTrue(all(not w.isEnabled() for w,c in self.window.actions if c.startswith('L')))
        self.inject_state(audio=audio_snapshot())
        self.assertEqual(self.window.controls['Z'].count(), 3)
        self.assertIn('1.5', self.window.controls['R'].itemText(0))
        self.assertIn('半幅缩小', self.window.actual_labels['Z'].text())
        self.assertTrue(all(w.isEnabled() for w,c in self.window.actions if c.startswith('L')))
        self.assertTrue(self.window.controls['Y'].isEnabled())
        self.inject_state(profile='control')
        self.assertFalse(self.window.controls['F'].isEnabled())
        self.assertFalse(self.window.sequence_upload_button.isEnabled())
        # The original standalone bitmap tool is independent of control/effects.
        self.wait_for(lambda:self.window.subtitle_bitmap is not None)
        self.assertTrue(self.window.subtitle_upload_button.isEnabled())
        self.assertTrue(self.window.controls['R'].isEnabled())
        self.inject_state(caps='NAMPIRQ')
        self.assertTrue(all(not b.isEnabled() for b in self.window.preset_buttons.values()))

    def test_disconnect_clears_actual_and_discards_outdated_preview(self):
        self.inject_state(audio=audio_snapshot())
        self.window.pool.waitForDone(5000)
        self.pump(30)
        token = self.window.preview_token
        self.window.on_event({'kind':'connection','connected':False,'text':'已断开'})
        self.assertIsNone(self.window.session.status)
        self.assertIsNone(self.window.session.audio)
        self.assertTrue(all(x.text() == '实际：—' for x in self.window.actual_labels.values()))
        old_title = self.window.asset_title.text()
        result = PreviewResult('STALE', title='STALE PAGE', image=Image.new('RGB',(16,16),'red'), page=1)
        self.window.preview_done(token, result)
        self.assertEqual(self.window.asset_title.text(), old_title)
        self.assertTrue(self.window.asset_image._original.isNull())

    def test_table_and_json_round_trip_without_sending(self):
        emitted=[]
        self.window.request.connect(emitted.append)
        self.window.story_table.item(0, 2).setText('3000')
        data=json.loads(self.window.story_json.toPlainText())
        self.assertEqual(data['entries'][0]['dwell_ms'],3000)
        data['entries'][0]['title_id']=7
        self.window.story_json.setPlainText(json.dumps(data))
        self.assertEqual(self.window.story_table.item(0,1).text(),'7')
        self.window.validate_story()
        self.assertIn('校验通过', self.window.message.text())
        self.assertEqual(emitted,[])

    def test_invalid_last_table_row_or_json_never_dispatches_upload(self):
        with patch.object(self.window,'dispatch') as dispatch:
            self.window.story_table.item(self.window.story_table.rowCount()-1,2).setText('abc')
            self.window.upload_story()
            dispatch.assert_not_called()
            self.window.story_tabs.setCurrentIndex(1)
            invalid=json.loads(self.window.story_json.toPlainText())
            invalid['entries'][-1]['source_id']=129
            self.window.story_json.setPlainText(json.dumps(invalid))
            self.window.upload_story()
            dispatch.assert_not_called()

    def test_invalid_table_cannot_upload_stale_json_after_switching_tab(self):
        with patch.object(self.window,'dispatch') as dispatch:
            self.window.story_table.item(self.window.story_table.rowCount()-1,2).setText('abc')
            self.window.story_tabs.setCurrentIndex(1)
            self.window.upload_story()
            dispatch.assert_not_called()

    def test_invalid_json_cannot_upload_stale_table_after_switching_tab(self):
        with patch.object(self.window,'dispatch') as dispatch:
            self.window.story_tabs.setCurrentIndex(1)
            self.window.story_json.setPlainText('{"schema":1,"entries":[')
            self.window.story_tabs.setCurrentIndex(0)
            self.window.upload_story()
            dispatch.assert_not_called()

    def test_subtitle_control_character_rejected_and_old_result_discarded(self):
        self.window.pool.waitForDone(5000)
        self.pump(30)
        old = self.window.subtitle_bitmap
        old_token=self.window.subtitle_token
        self.window.subtitle_text.setPlainText('禁止\x1b控制字符')
        self.window.subtitle_timer.stop()
        self.window.render_subtitle()
        self.wait_for(lambda:'校验失败' in self.window.subtitle_info.text())
        self.assertIsNone(self.window.subtitle_bitmap)
        self.assertFalse(self.window.subtitle_upload_button.isEnabled())
        if old is not None:
            self.window.subtitle_done(old_token,old)
            self.assertIsNone(self.window.subtitle_bitmap)

    def test_missing_font_glyph_rejected(self):
        self.window.pool.waitForDone(5000)
        self.pump(30)
        self.window.subtitle_text.setPlainText('测试')
        self.window.subtitle_timer.stop()
        with patch('subtitle_bitmap.font_coverage',return_value=frozenset()):
            self.window.render_subtitle()
            self.wait_for(lambda:'字体缺字' in self.window.subtitle_info.text())
        self.assertIsNone(self.window.subtitle_bitmap)

    def test_motion_switch_finishes_opacity_and_window_worker_closes(self):
        self.window.motion.setChecked(True)
        self.window.nav.setCurrentRow(1)
        self.pump(220)
        self.assertAlmostEqual(self.window.stack.graphicsEffect().opacity(),1.0)
        self.window.motion.setChecked(False)
        self.window.nav.setCurrentRow(2)
        self.assertAlmostEqual(self.window.stack.graphicsEffect().opacity(),1.0)
        self.assertFalse(self.window.stack._motion_enabled)
        self.window.close()
        self.assertFalse(self.window.thread.isRunning())


if __name__=='__main__':
    unittest.main(verbosity=2)
