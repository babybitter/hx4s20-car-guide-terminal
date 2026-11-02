"""Qt UI -> queued worker -> fragmented fake UART -> actual UI snapshots.

These are end-to-end software tests, never evidence of physical board output.
"""
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
sys.path.insert(0,str(ROOT/'legacy/tools/console'))
sys.path.insert(0,str(ROOT/'tests'))
sys.dont_write_bytecode=True

from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
from app.theme import STYLESHEET, configure_fonts
from app.ui import MainWindow
from test_backend import FakePort, document


class MissingReplyPort(FakePort):
    def __init__(self):
        super().__init__()
        self.waiting=threading.Event()
    def write(self,frame):
        count=super().write(frame)
        if frame==b'T3\r\n':
            self.rx.clear()
            self.waiting.set()
        return count


class QtIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=QApplication.instance() or QApplication([])
        configure_fonts()
        cls.app.setStyle('Fusion')
        cls.app.setStyleSheet(STYLESHEET)
        cls.app.setQuitOnLastWindowClosed(False)

    def setUp(self):
        from serial.tools.list_ports_common import ListPortInfo
        fake_port = ListPortInfo('FAKE-SOFTWARE-ONLY')
        fake_port.description = 'Software UART'
        self.port_guard=patch('serial.tools.list_ports.comports',return_value=[fake_port])
        self.serial_guard=patch('serial.Serial',side_effect=AssertionError('Physical serial forbidden'))
        self.port_guard.start()
        self.serial_guard.start()
        self.window=MainWindow(ROOT,demo=False)
        self.window.motion.setChecked(False)
        self.window.show()
        self.port=FakePort()
        self.window.worker.serial_factory=lambda **kwargs:self.port
        self.wait_for(lambda:not self.window._port_scan_active)
        self.window.port_combo.setCurrentIndex(self.window.port_combo.findData('FAKE-SOFTWARE-ONLY'))

    def tearDown(self):
        self.window.subtitle_timer.stop()
        self.window.close()
        self.window.pool.waitForDone(10000)
        self.app.processEvents()
        self.assertFalse(self.window.thread.isRunning())
        self.assertTrue(self.port.closed)
        self.window.deleteLater()
        QTest.qWait(20)
        self.port_guard.stop()
        self.serial_guard.stop()

    def wait_for(self,predicate,timeout=8):
        deadline=time.monotonic()+timeout
        while not predicate() and time.monotonic()<deadline:
            QTest.qWait(12)
            self.app.processEvents()
        self.assertTrue(predicate(), 'Qt fake-UART integration timeout: '+self.window.message.text())

    def connect_port(self):
        QTest.mouseClick(self.window.connect_button,Qt.MouseButton.LeftButton)
        self.wait_for(lambda:self.window.connected and not self.window.busy)
        self.assertIsNotNone(self.window.session.status)
        self.assertIn('Q',self.port.commands)
        self.assertFalse(self.port.closed)

    def test_preset_manual_story_disconnect_and_reconnect(self):
        self.connect_port()
        self.window.nav.setCurrentRow(1)
        self.window.next_page_check.setChecked(True)
        start=len(self.port.commands)
        QTest.mouseClick(self.window.preset_buttons['横擦'],Qt.MouseButton.LeftButton)
        self.wait_for(lambda:not self.window.busy and 'N' in self.port.commands[start:])
        commands=self.port.commands[start:]
        offset=commands.index('X0')
        self.assertEqual(commands[offset:offset+5],['X0','E1','T1','H','N'])
        self.assertEqual(self.window.controls['T'].currentIndex(),1)
        self.assertEqual(self.window.actual_labels['T'].text(),'实际：1')
        self.assertEqual(self.window.session.status.page,2)

        self.window.controls['T'].setCurrentIndex(2)
        self.window.controls['T'].activated.emit(2)
        self.wait_for(lambda:not self.window.busy and self.window.actual_labels['T'].text()=='实际：2')
        self.assertEqual(self.port.commands.count('T2'),1)

        self.window.nav.setCurrentRow(2)
        self.window.story_json.setPlainText(document(2))
        self.window.story_tabs.setCurrentIndex(1)
        start=len(self.port.commands)
        QTest.mouseClick(self.window.sequence_upload_button,Qt.MouseButton.LeftButton)
        self.wait_for(lambda:not self.window.busy and self.window.session.hardware.sequence_version==1)
        commands=self.port.commands[start:]
        self.assertIn('U',commands)
        self.assertIn('K02',commands)
        self.assertEqual(sum(c.startswith('J') for c in commands),2)
        self.assertEqual(self.window.session.hardware.sequence_count,2)
        self.assertNotIn('G1',commands)

        QTest.mouseClick(self.window.connect_button,Qt.MouseButton.LeftButton)
        self.wait_for(lambda:not self.window.connected and not self.window.busy)
        self.assertTrue(self.port.closed)
        self.assertIsNone(self.window.session.status)
        self.port=FakePort()
        self.connect_port()
        self.assertEqual(self.window.session.status.page,1)

    def test_cancel_pending_reply_disconnects_without_replay_then_reconnects(self):
        self.port=MissingReplyPort()
        self.connect_port()
        self.window.controls['T'].activated.emit(3)
        self.wait_for(lambda:self.port.waiting.is_set())
        self.assertTrue(self.window.busy)
        QTest.mouseClick(self.window.cancel_button,Qt.MouseButton.LeftButton)
        self.wait_for(lambda:not self.window.connected and not self.window.busy)
        self.assertTrue(self.port.closed)
        self.assertEqual(self.port.commands.count('T3'),1)
        self.assertIsNone(self.window.session.hardware)
        self.port=FakePort()
        self.connect_port()

    def test_close_during_inflight_command_releases_port_and_thread(self):
        self.port=MissingReplyPort()
        self.connect_port()
        self.window.controls['T'].activated.emit(3)
        self.wait_for(lambda:self.port.waiting.is_set())
        self.window.close()
        self.wait_for(lambda:not self.window.thread.isRunning())
        self.assertTrue(self.port.closed)
        self.assertEqual(self.port.commands.count('T3'),1)


if __name__=='__main__':unittest.main(verbosity=2)
