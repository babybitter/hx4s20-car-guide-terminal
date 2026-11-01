"""Reproducible offscreen screenshots of real Qt pages, no board simulation."""
import os
from pathlib import Path
import sys
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
sys.path.insert(0,str(ROOT/'legacy/tools/console'))
sys.dont_write_bytecode=True

from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from app.ui import MainWindow
from app.theme import STYLESHEET, configure_fonts


def main():
    app=QApplication.instance() or QApplication([])
    configure_fonts()
    app.setStyle('Fusion')
    app.setStyleSheet(STYLESHEET)
    app.setQuitOnLastWindowClosed(False)
    folder=ROOT/'evidence/ui'
    folder.mkdir(parents=True,exist_ok=True)
    with patch('serial.Serial',side_effect=AssertionError('No hardware in screenshot capture')), \
         patch('serial.tools.list_ports.comports',side_effect=AssertionError('No enumeration in demo')):
        window=MainWindow(ROOT,demo=True)
        window.motion.setChecked(False)
        window.show()
        QTest.qWait(500)
        window.pool.waitForDone(5000)
        app.processEvents()
        for theme in ('dark', 'light'):
            target_folder = folder / theme
            target_folder.mkdir(exist_ok=True)
            window.theme_combo.setCurrentIndex(window.theme_combo.findData(theme))
            for width,height in [(1600,1000),(1280,800)]:
                window.resize(width,height)
                QTest.qWait(100)
                for index,name in enumerate(['overview','effects','story','subtitle','audio','assets','diagnostics']):
                    window.nav.setCurrentRow(index)
                    QTest.qWait(100)
                    target=target_folder/f'{width}x{height}-{index+1:02d}-{name}-offline.png'
                    if not window.grab().save(str(target)):
                        raise RuntimeError(f'Could not save {target}')
                    print(theme, target.name)
        window.close()
        window.pool.waitForDone(5000)
        app.processEvents()
        if window.thread.isRunning():raise RuntimeError('Worker thread did not stop')
    print('28 real Qt page screenshots in dark/light; offline only, no fabricated board state.')


if __name__=='__main__':main()
