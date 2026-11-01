# HX4S20 Car Guide Terminal

基于安路 HX4S20C 开发板的车载导览乘车提示终端。通过 TF 卡存储导览图片与语音素材，使用 HDMI 输出画面和声音，配合板载按键、拨码开关及 Qt 上位机完成导览播放与显示控制。

## 功能

- 八页主题导览：线路总览、湖畔步道、林间展园、文明乘车、沿途人文、雨天出行、礼让同行、离车检查。
- 手动切页、自动轮播、四档播放周期，以及可编排的故事序列。
- 图像亮度、对比度、滤镜、缩放、淡化、横向及纵向转场。
- 中文语音播报、背景音乐、音量调节、静音与播报抢占。
- 启动动画、本地菜单、45像素底部导航栏与中文提示窗。
- 单行中英文滚动字幕：21像素字高、灰白文字、右下2像素半透明阴影与青色底线。
- 63个真实频点的彩虹音乐频谱，覆盖62.5—3937.5 Hz，与双声道PCM波形叠加；色相随播放缓慢流动。
- Qt 桌面控制台：参数调节、图片预览、字幕编辑、故事上传和设备状态查询。

语音由电脑端预先生成，FPGA 从音频素材包中读取播放。上位机图片预览读取本地 BMP 文件。

## 硬件与软件

| 项目 | 配置 |
|---|---|
| 开发板 / FPGA | 安路 HX4S20C / EG4S20BG256 |
| FPGA 开发工具 | Anlogic TD 6.2.1，内部版本 6.2.168116 |
| 图像 | 640 × 480，24 位无压缩 BMP |
| 存储卡 | 64 GB TF，FAT32 |
| 显示与音频 | HDMI-A，显示器或 HDMI 音频设备 |
| 上位机 | Windows、Python 3.11、PySide6 |
| 串口 | 板载 CH340，115200 baud，8N1，无流控 |

## 目录

```text
hx4s20-car-guide-terminal/
├─ fpga/src/
│  ├─ td_project/             # 唯一 TD 工程与 PLL/IP 配置
│  └─ user_source/            # HDL、ADC 引脚约束及 SDC 时序约束
├─ host/qt/                   # HX4S20 Studio 上位机
├─ tools/
│  ├─ audio/                 # AUDIO.BIN、音频素材及制作脚本
│  ├─ bmp/                   # 官方图片转换脚本及编号 BMP
│  └─ images/                # 图片源素材
├─ assets/                   # 图片目录清单
├─ firmware/                 # FPGA bit 文件及版本信息
└─ provenance/               # 源码版本与文件来源信息
```

## 编译 FPGA 工程

使用 TD 打开：

```text
fpga/src/td_project/car_guide_terminal.al
```

顶层模块为 `car_terminal_top`，器件为 `EG4S20BG256`。工程已包含 HDMI-A、按键、开关、串口及其他接口的引脚约束。

依次执行综合、布局、布线和 Generate Bitstream。若 TD 提示将非默认参数恢复为默认值，选择 **Cancel** 保留工程设置：`opt_area=high`、`pack_effort=high`、`hfn_opt_effort=low`、`pr_strategy=5`。

生成文件位于：

```text
fpga/src/td_project/car_guide_terminal_Runs/phy_1/
    car_guide_terminal.bit
```

`firmware/car_guide_terminal.bit` 保留最初导入仓库的固件。使用上述工程重新生成包含当前界面功能的 bit，再通过 TD 的 PROGRAM_FLASH 写入开发板，完成后重新上电。

## 准备 TF 卡

将以下文件复制到 FAT32 TF 卡根目录：

1. `tools/bmp/output_bmp/catalog/001.BMP` 至 `008.BMP`。
2. `tools/audio/AUDIO.BIN`。

保留文件名。图片目录和 FPGA 内部素材 CRC 表对应；更换图片像素内容时需要同步更新 CRC 表并重新编译工程。图片转换脚本为 `tools/bmp/convert_images_to_bmp.py`。

## 板载操作

初始设置：`SW3=0`、`SW4=0`。显示器连接 **HDMI-A** 并启用扬声器。

| 控件 | 功能 |
|---|---|
| KEY1 | 复位并重新装载素材 |
| KEY2 | 下一页；菜单开启时选择项目 |
| KEY3 | 乘车提示窗与安全语音；菜单开启时编辑项目 |
| KEY4 | 轮播启停，故事暂停/恢复；菜单开启时应用项目 |
| SW2 SW1 | `00 / 01 / 10 / 11` 对应停留 `1.5 / 3 / 5 / 8` 秒 |
| SW3 | `1` 打开本地菜单，`0` 关闭 |
| SW4 | `1` 静音，`0` 恢复声音 |

停留时间之外还包含素材装载和转场时间。提示窗显示期间暂停自动播放计时。

## 使用上位机

在 `host/qt` 目录创建 Python 环境并启动：

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe main.py
```

选择“完整控制 · effects”、开发板对应的 CH340 串口和 115200 波特率，然后连接设备。界面提供图像效果、播放与故事、音频、字幕及设备查询等操作。`main.py --demo` 可打开离线界面。

语音与音乐模式为 `L0` 关闭、`L1` 语音、`L2` 音乐、`L3` 语音与音乐。音量为 `V0` 至 `V4`，其中 `V0` 静音。图片缩放为 `Z0` 原图、`Z1` 中心放大、`Z2` 半幅。

中文字幕最多40个字符，输入中的换行与制表符转换为空格，以单行从右向左循环播放。文字与英文字幕保持相同字高。

频谱使用分时 Goertzel 分析器，63个独立频点共享运算单元和状态存储。频谱与波形面板为608×56像素，和字幕内容区等宽，在各档缩放下保持固定位置并紧贴字幕。63根细柱采用完整彩虹色环，播放时缓慢轮换色相，静音时柱高逐步回落。双声道PCM波形使用灰白、青白线条和双缓冲整帧更新；`Y0`—`Y4` 控制背景透明度，彩色柱形和波形保持清晰。显示风格参考 [Music-Spectrum](https://github.com/aystmjz/Music-Spectrum) 的彩虹频谱与波形叠加思路。

## 来源

项目使用安路及康芯配套例程、IP 和用户提供的高级效果方案，并包含项目开发的导览、控制、音频调度与显示模块。第三方组成和分发事项见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
