S19 离线语音与空闲BGM素材工具

所有输入、脚本、输出位于 project/tools/audio。板端集成入口与验收见 docs/语音与演示交互优化方案.md。
本目录的触发/优先级字段属于素材规划建议；实际已实现调度、冷却与淡变以对应阶段的RTL和中文测试单为准。

先看：
  FORMAT.txt                 最终纯数据格式、ID、ROM时序及解码契约
  manifest.json              26条中文、触发、优先级、冷却和调度建议
  reports/build_report.json  实测时长、文件长度、CRC32/SHA256及接缝指标

板端素材与索引（必须成套保持一致）：
  AUDIO.BIN                  无头纯μ-law包，512字节对齐，ID31为32秒BGM
  audio_asset_rom.v           64x32单读口同步ROM候选、精确长度/CRC/ID位图常量
  package_manifest.json      与包对应的32槽索引、每条实测统计、来源hash

试听：
  preview/index.html             本地双列播放器，对比PCM和包提取μ-law
  preview/speech_reel_mulaw.wav   按ID0..25串接试听，每条间隔350ms
  preview/speech_reel_pcm.wav     相同顺序PCM对照
  preview/playlist.csv           每条文字、时长、合辑起点及索引
  pcm_wav/31_idle_bgm.wav        32秒16k/16bit/mono原创BGM
  decoded_wav/31_idle_bgm.wav    AUDIO.BIN实际提取解码BGM
  preview/bgm_two_loops_mulaw.wav 64秒连续两轮，32秒处为接缝
  preview/bgm_seam_mulaw.wav      接缝前后各2秒
  pcm_wav/                      26条处理后的PCM语音，均约1–3秒
  decoded_wav/                  每条μ-law包提取解码，含BGM
  mulaw/                        无封装、无填充的独立.ulaw片段
  raw_wav/                      System.Speech原始输出与本机语音来源信息

原创旋律配色：
  bgm_score.py                  合成与导出共用的原始编曲
  bgm_melody.json / .csv         16个主旋律事件：MIDI音高、频率、16k采样起止位置
  bgm_melody_rom.v / .hex        可选32x32同步读表，每事件两条记录
  export_bgm_melody.py           独立导出入口，修改编曲/重建音频后应重新运行
使用BGM的实际sample_index寻址，暂停时冻结、续播从记录位置恢复。
音符颜色来自已知原创主旋律；最新音起点优先，结束后空档为休止。
和弦及回声仍可能同时发声，表格不声称多声部实时识别。实时语音使用频带配色。
32bit SDRAM的固定字节映射及offset_byte>>2地址换算见FORMAT.txt第4节。

离线生成（从仓库根目录；Windows PowerShell或PowerShell 7均可）：
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/audio/build.ps1
保留原始TTS，仅重做PCM处理/BGM/打包/测试：
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/audio/build.ps1 -ReuseRaw
单独运行：
  python -B tools/audio/build_assets.py build
  python -B tools/audio/build_assets.py inspect
  python -B tools/audio/build_assets.py decode --id 24
  python -B tools/audio/test_audio_assets.py
  python -B tools/audio/check_reproducibility.py
  python -B project/.tooling/s19-audio-assets/export_bgm_melody.py

系统需求：Windows本机System.Speech与Microsoft Huihui Desktop中文声音；Python3.9+。
无pip依赖，不联网。Python3.11 audioop仅作可选独立参考，生成/解码不依赖audioop；
Python3.13+跳过该对照测试，仍运行已知向量、全范围及格式检查。
本机有Icarus Verilog则额外编译/运行本目录生成ROM的64项同步读测试，不调用TD。

复现：脚本中所有输出路径固定在脚本目录；build拒绝文字/voice/hash不匹配的旧TTS。
修改manifest文字应先重跑generate_tts.ps1，然后再build。ID不能重新编号。
build.ps1默认重新合成，原始TTS确定性及固定原始输入重建证据见reports/reproducibility.json。
不要单独更新AUDIO.BIN或ROM。用户自行把AUDIO.BIN复制到TF根目录；不需要替换既有编号BMP，不自动操作TF或Flash。

听感待人工确认；本目录的PASS只说明工具、格式、音频数值和ROM读时序通过检查。
