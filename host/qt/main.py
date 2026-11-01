"""Independent Qt entry point; never imports or writes the active FPGA project."""
import argparse
from pathlib import Path
import sys

ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'legacy' / 'tools' / 'console'))

def main():
    parser = argparse.ArgumentParser(description='HX4S20 Terminal Studio · Qt')
    parser.add_argument('--demo', action='store_true', help='本地界面预览；不连接、不模拟板端状态')
    parser.add_argument('--profile', choices=['control', 'effects'], default='effects')
    parser.add_argument('--smoke-screenshot', help=argparse.SUPPRESS)
    args = parser.parse_args()
    from PySide6.QtWidgets import QApplication
    from PySide6.QtGui import QIcon
    from PySide6.QtCore import QTimer
    from app.ui import MainWindow
    from app.theme import configure_fonts
    from app.appearance import AppearanceController
    app = QApplication(sys.argv[:1])
    app.setApplicationName('HX4S20 Terminal Studio')
    app.setOrganizationName('HX4S20')
    app.setWindowIcon(QIcon(str(ROOT / 'assets/app.ico')))
    app.setStyle('Fusion')
    configure_fonts()
    preference_root = Path(sys.executable).resolve().parent if getattr(sys, 'frozen', False) else ROOT
    appearance = AppearanceController(app, preference_root / 'config/ui_preferences.json')
    window = MainWindow(ROOT, demo=args.demo, profile=args.profile, appearance=appearance)
    window.show()
    if args.smoke_screenshot:
        def capture():
            window.grab().save(args.smoke_screenshot)
            window.close()
        QTimer.singleShot(1800, capture)
    return app.exec()

if __name__ == '__main__':
    raise SystemExit(main())
