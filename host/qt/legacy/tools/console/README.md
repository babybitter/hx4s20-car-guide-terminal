# HX4S20 协议与素材支持模块

本目录由同一工作区 `HX4S20_QtConsole/legacy/tools/console` 整理而来，保留原模块名和资源相对目录。文件出处与摘要见 Qt 根目录的 `source-manifest.json`。

- `protocol.py`：Q/H/AQ 协议、命令校验与 Session。
- `sequence.py`、`sequence.schema.json`、`examples/`：故事序列和格式示例。
- `subtitle_bitmap.py`、`subtitle_cli.py`：字幕渲染、位图协议及命令行工具。
- `local_preview.py`：本地 BMP 清单、SHA-256 和像素 CRC 校验。
- `audio_cli.py`、`audio_labels.py`：离线 AQ 解析和音频标签。
- `fixtures/`、`tests/`、`run_tests.py`：协议及数据模块离线回归。

桌面界面入口位于上层 Qt 根目录的 `main.py`；旧 Tk 窗口不再随本目录分发。音频标签来自原 Qt 工程 `app/audio_labels.py`，不导入 Tk 或 PySide6。
