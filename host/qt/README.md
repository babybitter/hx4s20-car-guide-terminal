# car_guide_terminal · HX4S20 Terminal Studio

基于 Python / PySide6 的 HX4S20 车载导览终端桌面控制台，提供设备控制、画面效果、故事编排、中文字幕、语音与背景音乐及本地素材浏览。支持浅色、深色和跟随系统外观。

## 功能

- 串口设备连接与状态读取，支持基础控制和高级效果两种配置档。
- 亮度、滤镜、缩放、转场、自动播放及组合预设控制。
- JSON 故事序列编辑与上传，支持字幕位图渲染和上传。
- 语音、背景音乐模式控制与音频状态显示。
- 按素材清单浏览本地 BMP 图片，显示文件信息和校验结果。
- 诊断日志、请求状态和设备实际状态显示。

## 运行

使用 Windows 64 位 Python 3.11 或以上版本。在本目录打开 PowerShell：

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe main.py
```

也可双击本目录的 `启动上位机.bat`。脚本优先使用 `dist/HX4S20_Studio/HX4S20_Studio.exe`，其次使用本目录 `.venv`。

```powershell
# 浏览本地界面
.venv\Scripts\python.exe main.py --demo
# 连接基础控制固件
.venv\Scripts\python.exe main.py --profile control
# 连接高级效果固件（默认配置档）
.venv\Scripts\python.exe main.py --profile effects
```

`预览界面.bat` 启动本地界面预览模式。连接设备时，在设备页选择 USB-UART 串口；通信参数为 115200、8N1。可用操作随设备能力更新。

源码版的外观设置保存到 `config/ui_preferences.json`；免安装版保存到 EXE 同目录的 `config/ui_preferences.json`。

故事编排页可导入 `legacy/tools/console/examples/s43_qt_demo.json`，包含八页、每页三秒的转场演示；`s17_transitions.json` 提供另一组转场故事。故事格式由 `legacy/tools/console/sequence.schema.json` 描述。免安装版的示例位于 `_internal/legacy/tools/console/examples/`。

## 构建 Windows 免安装版

```powershell
.venv\Scripts\python.exe -m pip install -r requirements-build.txt
.venv\Scripts\python.exe build_exe.py
```

构建目录为 `build/`，输出目录为 `dist/HX4S20_Studio/`。分发时复制整个输出目录，保留 `_internal/` 和 `LICENSES/`。可用 `--dist-dir PATH` 指定输出父目录。

`requirements-lock.txt` 列出组件版本，可用 `python -m pip install -r requirements-lock.txt` 安装锁定版本。

## 源码与资源

| 路径 | 内容 |
|---|---|
| `main.py`、`app/` | Qt 入口、窗口、串口服务及主题 |
| `assets/app.ico`、`assets/app.png` | 程序图标 |
| `legacy/tools/console/` | 协议、序列、字幕位图、本地预览、CLI 及配套数据 |
| `legacy/assets/catalog_manifest.json` | 本地素材清单 |
| `legacy/tools/bmp/output_bmp/catalog/001.BMP`—`008.BMP` | 八张本地素材图片 |
| `source-manifest.json` | 源模块出处与文件摘要 |
| `第三方组件说明.md`、`pyserial-LICENSE.txt` | 第三方组件说明与许可证 |

`legacy` 保留上游模块名称和资源相对路径。运行与构建所需文件均位于本目录；`docs/` 是可选的本地文档，不参与程序构建。
