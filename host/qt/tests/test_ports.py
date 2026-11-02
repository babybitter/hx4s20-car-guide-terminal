"""COM discovery and selection using OS metadata doubles, never physical UARTs."""
import os
from pathlib import Path
import sys
import threading
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
from serial.tools.list_ports_common import ListPortInfo
from app.ui import MainWindow


def port(device, description='n/a'):
    value = ListPortInfo(device)
    value.description = description
    return value


class PortPickerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        cls.app.setQuitOnLastWindowClosed(False)

    def setUp(self):
        self.physical = patch('serial.Serial', side_effect=AssertionError('Physical serial forbidden'))
        self.serial_mock = self.physical.start()
        self.discovery = patch('serial.tools.list_ports.comports', return_value=[
            port('COM10'), port('COM8', 'USB-SERIAL CH340 (COM8)'), port('COM3')])
        self.scan = self.discovery.start()
        self.window = MainWindow(ROOT)
        self.window.motion.setChecked(False)
        self.window.show()
        self.wait_for(lambda: not self.window._port_scan_active)
        self.window.port_timer.stop()

    def tearDown(self):
        self.window.close()
        self.window.pool.waitForDone(5000)
        self.app.processEvents()
        self.assertFalse(self.window.thread.isRunning())
        self.assertFalse(self.window.port_timer.isActive())
        self.assertFalse(self.window.port_result_timer.isActive())
        self.serial_mock.assert_not_called()
        self.window.deleteLater()
        QTest.qWait(10)
        self.discovery.stop()
        self.physical.stop()

    def wait_for(self, predicate):
        deadline = time.monotonic() + 5
        while not predicate() and time.monotonic() < deadline:
            QTest.qWait(10)
        self.assertTrue(predicate(), 'Timed out waiting for Qt discovery')

    def refresh(self, ports):
        self.scan.return_value = ports
        self.window.refresh_ports()
        self.wait_for(lambda: not self.window._port_scan_active)

    def choose(self, device):
        self.window.port_combo.setCurrentIndex(self.window.port_combo.findData(device))

    def test_startup_lists_natural_order_and_requires_explicit_choice(self):
        combo = self.window.port_combo
        self.assertEqual([combo.itemData(i) for i in range(combo.count())], ['COM3', 'COM8', 'COM10'])
        self.assertEqual(combo.itemText(1), 'COM8 · USB-SERIAL CH340')
        self.assertFalse(combo.isEditable())
        self.assertEqual(combo.currentIndex(), -1)
        self.assertFalse(self.window.connect_button.isEnabled())
        self.assertIn('3', self.window.port_status.text())
        self.choose('COM8')
        self.assertTrue(self.window.connect_button.isEnabled())
        with patch.object(self.window, 'dispatch') as dispatch:
            QTest.mouseClick(self.window.connect_button, Qt.LeftButton)
            dispatch.assert_called_once_with({'action': 'connect', 'port': 'COM8', 'profile': 'effects'})

    def test_refresh_preserves_choice_and_removal_never_selects_another(self):
        self.choose('COM8')
        self.refresh([port('COM8', 'CH340 renamed'), port('COM2')])
        self.assertEqual(self.window.port_combo.currentData(), 'COM8')
        self.assertIn('renamed', self.window.port_combo.currentText())
        self.refresh([port('COM2')])
        self.assertIsNone(self.window.port_combo.currentData())
        self.assertFalse(self.window.connect_button.isEnabled())

    def test_timer_detects_insert_and_remove_without_clicking_refresh(self):
        self.refresh([])
        self.assertIn('未检测到', self.window.port_status.text())
        self.assertEqual(self.window.port_timer.interval(), 2000)
        self.scan.return_value = [port('COM8', 'USB-SERIAL CH340')]
        self.window.port_timer.start(25)
        self.wait_for(lambda: self.window.port_combo.findData('COM8') >= 0)
        self.choose('COM8')
        self.scan.return_value = []
        self.wait_for(lambda: self.window.port_combo.count() == 0)
        self.assertFalse(self.window.connect_button.isEnabled())

    def test_reused_com_number_with_changed_hardware_requires_new_selection(self):
        original = port('COM8', 'USB-SERIAL CH340')
        original.hwid = 'USB VID:PID=1A86:7523 SER=original'
        self.refresh([original])
        self.choose('COM8')
        replacement = port('COM8', 'USB-SERIAL CH340')
        replacement.hwid = 'USB VID:PID=1A86:7523 SER=replacement'
        self.refresh([replacement])
        self.assertEqual(self.window.port_combo.count(), 1)
        self.assertIsNone(self.window.port_combo.currentData())
        self.assertFalse(self.window.connect_button.isEnabled())

    def test_close_does_not_wait_for_blocked_device_enumeration(self):
        entered, release, returned = threading.Event(), threading.Event(), threading.Event()
        def blocked_scan():
            entered.set()
            release.wait(5)
            returned.set()
            return []
        self.scan.side_effect = blocked_scan
        self.window.pool.waitForDone(5000)  # Finish the unrelated subtitle preview.
        try:
            self.window.refresh_ports()
            self.wait_for(entered.is_set)
            started = time.monotonic()
            self.window.close()
            self.assertLess(time.monotonic() - started, 1.0)
            self.assertFalse(returned.is_set())
            self.assertFalse(self.window.thread.isRunning())
            self.assertFalse(self.window.port_result_timer.isActive())
        finally:
            release.set()
        self.wait_for(returned.is_set)
        self.app.processEvents()  # No post-close Qt updates from the late result.

    def test_discovery_failure_is_visible_and_refresh_recovers(self):
        self.choose('COM8')
        self.scan.side_effect = OSError('mock device service unavailable')
        self.window.refresh_ports()
        self.wait_for(lambda: not self.window._port_scan_active)
        self.assertIn('检测失败', self.window.port_status.text())
        self.assertIn('unavailable', self.window.port_status.toolTip())
        self.assertEqual(self.window.port_combo.count(), 0)
        self.assertFalse(self.window.connect_button.isEnabled())
        self.assertTrue(self.window.port_refresh_button.isEnabled())
        self.scan.side_effect = None
        self.refresh([port('COM8')])
        self.assertEqual(self.window.port_combo.count(), 1)
        self.assertEqual(self.window.port_combo.currentIndex(), -1)

    def test_connected_or_busy_does_not_scan_or_replace_selection(self):
        self.choose('COM8')
        for state in ('connected', 'busy'):
            with self.subTest(state=state):
                setattr(self.window, state, True)
                self.window.update_enabled()
                self.assertFalse(self.window.port_combo.isEnabled())
                self.assertFalse(self.window.port_refresh_button.isEnabled())
                before = self.scan.call_count
                self.window.refresh_ports()
                self.assertEqual(self.scan.call_count, before)
                # A result from before connection must also be discarded.
                self.window.ports_refreshed(self.window._port_scan_token, [])
                self.assertEqual(self.window.port_combo.currentData(), 'COM8')
                setattr(self.window, state, False)

    def test_background_scan_does_not_block_ui_or_duplicate_pending_work(self):
        entered, release = threading.Event(), threading.Event()
        threads = []
        def slow_scan():
            threads.append(threading.get_ident())
            entered.set()
            release.wait(3)
            return [port('COM8')]
        self.scan.side_effect = slow_scan
        try:
            self.window.refresh_ports()
            self.wait_for(entered.is_set)
            before = self.scan.call_count
            self.window.refresh_ports()
            self.assertEqual(self.scan.call_count, before)
            self.assertNotEqual(threads[0], threading.get_ident())
            self.window.nav.setCurrentRow(1)
            self.assertEqual(self.window.stack.currentIndex(), 1)
            self.choose('COM8')
        finally:
            release.set()
        self.wait_for(lambda: not self.window._port_scan_active)
        self.assertEqual(self.window.port_combo.currentData(), 'COM8')

    def test_open_dropdown_is_stable_until_user_finishes_selecting(self):
        self.choose('COM8')
        self.window.port_combo.showPopup()
        try:
            before = self.scan.call_count
            self.window.refresh_ports()
            self.assertEqual(self.scan.call_count, before)
            self.window.ports_refreshed(self.window._port_scan_token, [])
            self.assertEqual(self.window.port_combo.currentData(), 'COM8')
        finally:
            self.window.port_combo.hidePopup()
        self.refresh([])
        self.assertEqual(self.window.port_combo.count(), 0)

    def test_empty_and_duplicate_metadata_do_not_create_invalid_choices(self):
        self.refresh([port(''), port('COM8'), port('COM8', 'CH340'), port('COM1', None)])
        combo = self.window.port_combo
        self.assertEqual([combo.itemData(i) for i in range(combo.count())], ['COM1', 'COM8'])
        self.assertEqual(combo.itemText(0), 'COM1')
        self.assertEqual(combo.itemText(1), 'COM8 · CH340')

    def test_demo_does_not_enumerate_or_connect(self):
        before = self.scan.call_count
        demo = MainWindow(ROOT, demo=True)
        try:
            self.assertFalse(demo.port_timer.isActive())
            self.assertFalse(demo.port_combo.isEnabled())
            self.assertFalse(demo.port_refresh_button.isEnabled())
            self.assertFalse(demo.connect_button.isEnabled())
            demo.refresh_ports()
            self.assertEqual(self.scan.call_count, before)
        finally:
            demo.close()
            demo.pool.waitForDone(5000)
            demo.deleteLater()
            QTest.qWait(10)


if __name__ == '__main__':
    unittest.main(verbosity=2)
