"""Appearance persistence and real-Qt interaction without physical serial I/O."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "legacy/tools/console"))
sys.dont_write_bytecode = True

from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
from app.appearance import AppearanceController
from app.ui import MainWindow


class AppearanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        cls.app.setQuitOnLastWindowClosed(False)
        cls.app.setStyle("Fusion")
        cls.scratch = ROOT / "evidence" / ".test-tmp"
        cls.scratch.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="appearance-", dir=self.scratch)
        self.path = Path(self.temp.name) / "appearance.json"
        self.controllers = []
        self.window = None
        self.serial_guard = patch("serial.Serial", side_effect=AssertionError("Appearance must never open a physical serial port"))
        self.ports_guard = patch("serial.tools.list_ports.comports", side_effect=AssertionError("Offline theme tests must not enumerate ports"))
        self.serial_guard.start()
        self.ports_guard.start()

    def controller(self):
        controller = AppearanceController(self.app, settings_path=self.path)
        self.controllers.append(controller)
        return controller

    def tearDown(self):
        if self.window is not None:
            self.window.subtitle_timer.stop()
            self.window.close()
            self.window.pool.waitForDone(5000)
            QTest.qWait(30)
            self.assertFalse(self.window.thread.isRunning())
            self.window.deleteLater()
        for controller in self.controllers:
            controller.deleteLater()
        QTest.qWait(20)
        self.app.processEvents()
        self.serial_guard.stop()
        self.ports_guard.stop()
        self.temp.cleanup()

    def test_selected_mode_is_saved_and_restored_on_reopen(self):
        controller = self.controller()
        controller.set_mode("dark")
        self.assertEqual(controller.mode, "dark")
        self.assertEqual(controller.effective_mode, "dark")
        self.assertTrue(self.path.is_file())
        # Verify a real JSON file and reconstruction, not an in-memory cache.
        self.assertIsInstance(json.loads(self.path.read_text(encoding="utf-8")), dict)
        reopened = self.controller()
        self.assertEqual(reopened.mode, "dark")
        self.assertEqual(reopened.effective_mode, "dark")
        reopened.set_mode("light")
        third = self.controller()
        self.assertEqual((third.mode, third.effective_mode), ("light", "light"))

    def test_corrupt_settings_fall_back_to_system_without_crash(self):
        self.path.write_text('{"mode": broken JSON', encoding="utf-8")
        with patch.object(AppearanceController, "system_effective_mode", return_value="light"):
            controller = self.controller()
        self.assertEqual(controller.mode, "system")
        self.assertEqual(controller.effective_mode, "light")
        controller.set_mode("dark")
        self.assertEqual(self.controller().mode, "dark")

    def test_system_changes_follow_only_in_system_mode(self):
        with patch.object(AppearanceController, "system_effective_mode", return_value="light"):
            controller = self.controller()
        events = []
        controller.changed.connect(lambda mode, effective: events.append((mode, effective)))
        self.assertEqual((controller.mode, controller.effective_mode), ("system", "light"))
        with patch.object(controller, "system_effective_mode", return_value="dark"):
            controller._system_changed()
        self.assertEqual((controller.mode, controller.effective_mode), ("system", "dark"))
        self.assertIn(("system", "dark"), events)
        controller.set_mode("light")
        with patch.object(controller, "system_effective_mode", return_value="dark"):
            controller._system_changed()
        self.assertEqual((controller.mode, controller.effective_mode), ("light", "light"))
        with patch.object(controller, "system_effective_mode", return_value="dark"):
            controller.set_mode("system")
        self.assertEqual((controller.mode, controller.effective_mode), ("system", "dark"))

    def test_window_theme_switch_keeps_edits_page_motion_and_no_serial_requests(self):
        controller = self.controller()
        self.window = MainWindow(ROOT, demo=True, appearance=controller)
        window = self.window
        window.show()
        QTest.qWait(30)
        requests = []
        window.request.connect(requests.append)
        self.assertEqual({window.theme_combo.itemData(i) for i in range(window.theme_combo.count())},
                         {"system", "light", "dark"})
        subtitle = "主题切换保留字幕\n下一站：人民广场"
        unfinished_story = '{"schema":1,"entries": [  '
        window.subtitle_text.setPlainText(subtitle)
        window.story_json.setPlainText(unfinished_story)
        window.nav.setCurrentRow(3)
        window.motion.setChecked(False)
        page, title = window.stack.currentIndex(), window.page_heading.text()
        for mode in ("light", "dark", "system"):
            with self.subTest(mode=mode):
                index = window.theme_combo.findData(mode)
                window.theme_combo.setCurrentIndex(index)
                window.theme_combo.activated.emit(index)
                QTest.qWait(25)
                self.assertEqual(controller.mode, mode)
                self.assertEqual(window.subtitle_text.toPlainText(), subtitle)
                self.assertEqual(window.story_json.toPlainText(), unfinished_story)
                self.assertEqual(window.stack.currentIndex(), page)
                self.assertEqual(window.page_heading.text(), title)
                self.assertFalse(window.motion.isChecked())
                self.assertIsNone(window.worker.port)
                self.assertIsNone(window.session.status)
        self.assertEqual(requests, [], "Theme changes must not become device commands")


if __name__ == "__main__":
    unittest.main()
