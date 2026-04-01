# Phase 7：上位机与 Web 频谱可视化

> 所属项目：XDMA + FFT 音乐频谱分析仪
> 前置依赖：Phase 6（驱动安装，DMA + FFT 通路验证通过）
> 后续阶段：无（项目最终阶段）

## 一、目标

开发完整的上位机应用，实现 MP3 解码、DMA 传输、FPGA FFT 处理、Web 实时频谱可视化。

## 二、远程操作环境

与 Phase 6 相同，所有远程操作通过 MCP 工具完成：

| 工具 | 用途 |
|------|------|
| `ssh-client` (exec / sudo_exec / SFTP) | 远程命令执行、文件上传下载、启动服务 |

**远程环境约束**：
- Python 3.6.9（Ubuntu 18.04 自带）— 不支持 walrus operator (`:=`)、不支持 `uv`
- 依赖管理使用 `pip3`（非 uv）
- 远程工作目录：`~/workplace/fft`

## 三、技术栈

| 组件 | 选型 | 说明 |
|------|------|------|
| 语言 | Python 3.6+ | 远程机实际版本 3.6.9 |
| 包管理 | pip3 | requirements.txt 管理依赖 |
| 音频解码 | pydub + ffmpeg | MP3 → PCM |
| Web 框架 | Flask | 同步 HTTP + 简单 WebSocket（兼容 3.6） |
| WebSocket | flask-sock 或 simple-websocket | Flask 生态下的 WebSocket |
| 前端 | HTML5 + Canvas + vanilla JS | 无需前端构建工具 |

### 依赖清单

文件：`prj/04/host/requirements.txt`（本地编写，SFTP 上传）

```
numpy
pydub
flask
flask-sock
```

> **ffmpeg**：pydub 依赖系统安装的 ffmpeg。通过 SSH 执行 `sudo apt install ffmpeg` 安装。

### 依赖安装

通过 ssh-client exec 执行：

```bash
cd ~/workplace/fft && pip3 install --user -r requirements.txt
```

## 四、项目结构

```
本地 prj/04/host/         SFTP 上传 →    远程 ~/workplace/fft/
├── requirements.txt                      ├── requirements.txt
├── fft_spectrum.py                       ├── fft_spectrum.py
├── static/                               ├── static/
│   └── index.html                        │   └── index.html
├── test_dma.py                           ├── test_dma.py
└── test_fft.py                           └── test_fft.py
```

开发流程：本地编写代码 → SFTP 上传 → SSH 执行/测试 → 查看输出

## 五、后端设计

### 5.1 整体架构

```
                    fft_spectrum.py (远程 ~/workplace/fft/)
┌──────────────────────────────────────────────────┐
│                                                  │
│  [AudioPipeline]                                 │
│   MP3 file → pydub decode → mono → 分帧(1024)   │
│        │                                         │
│        ▼                                         │
│  [DMAWorker Thread]                              │
│   frame → pack to 128-bit → write /dev/h2c      │
│   read /dev/c2h → unpack 16-bit magnitudes      │
│        │                                         │
│        ▼                                         │
│  [Flask + WebSocket]                             │
│   /ws/spectrum → push JSON {bins: [...]}         │
│   /static/     → serve index.html                │
│                                                  │
└──────────────────────────────────────────────────┘

本地浏览器 ← http://192.168.2.101:8000 ← Flask 服务
```

### 5.2 音频处理管线

```python
# 伪代码（兼容 Python 3.6）
def load_audio(mp3_path):
    audio = AudioSegment.from_mp3(mp3_path)
    audio = audio.set_channels(1)           # 立体声 → 单声道
    audio = audio.set_sample_width(2)       # 16-bit
    audio = audio.set_frame_rate(44100)     # 44.1kHz
    pcm = np.frombuffer(audio.raw_data, dtype=np.int16)
    return pcm

def frame_generator(pcm, frame_size=1024):
    for i in range(0, len(pcm) - frame_size + 1, frame_size):
        yield pcm[i : i + frame_size]
```

### 5.3 DMA 读写

XDMA Gen3 x4 的 AXI-Stream 数据宽度为 **128-bit (16 bytes)**。每个 128-bit beat 中只放一个 16-bit 采样点在最低 2 字节，其余补零。

```python
# 伪代码
H2C_DEV = "/dev/xdma0_h2c_0"
C2H_DEV = "/dev/xdma0_c2h_0"
BEAT_SIZE = 16  # 128-bit = 16 bytes per beat
FRAME_SIZE = 1024

# 文件描述符保持常开，避免每帧 open/close 的系统调用开销
h2c_fd = open(H2C_DEV, 'wb', buffering=0)
c2h_fd = open(C2H_DEV, 'rb', buffering=0)

def dma_process_frame(frame_1024):
    # 打包：每个 16-bit 样本放入 128-bit beat 的最低 2 字节
    buf = np.zeros(FRAME_SIZE * BEAT_SIZE // 2, dtype=np.int16)
    for i in range(FRAME_SIZE):
        buf[i * (BEAT_SIZE // 2)] = frame_1024[i]

    h2c_fd.seek(0)
    h2c_fd.write(buf.tobytes())  # 写入 1024 × 16 = 16384 bytes

    c2h_fd.seek(0)
    raw = c2h_fd.read(FRAME_SIZE * BEAT_SIZE)  # 读回 16384 bytes

    # 提取每个 128-bit beat 的低 16 位（无符号幅度）
    result = np.frombuffer(raw, dtype=np.uint16).reshape(FRAME_SIZE, BEAT_SIZE // 2)
    magnitudes = result[:, 0].astype(np.float32)
    return magnitudes[:512]  # 只取前 N/2 个 bin（对称性）
```

> **帧同步**：每次 write 恰好写入 16384 bytes（1024 × 16），XDMA 在传输结束时生成 `tlast`，FFT 以此识别帧边界。read 也读取 16384 bytes，对应一帧完整的频谱结果。write 和 read 均为阻塞式，在 23.2 ms 的帧间隔内完成（实际 DMA + FFT 处理耗时 < 1 ms）。

### 5.4 WebSocket 推送

```python
# Flask + flask-sock（兼容 Python 3.6）
@sock.route('/ws/spectrum')
def spectrum_ws(ws):
    while True:
        spectrum = spectrum_queue.get()  # 从 DMA 线程获取
        # 归一化到 0~1
        normalized = spectrum / (spectrum.max() + 1e-6)
        ws.send(json.dumps({"bins": normalized.tolist()}))
```

### 5.5 帧率与节奏控制

音频采样率 44100 Hz，帧大小 1024，理论帧率 ≈ 43 fps。

DMA 线程需要按音频实际播放速度发送帧，避免发送过快导致缓冲溢出：

```python
frame_duration = 1024 / 44100  # ≈ 23.2 ms
for frame in frame_generator(pcm):
    t0 = time.monotonic()
    spectrum = dma_process_frame(frame)
    spectrum_queue.put(spectrum)
    elapsed = time.monotonic() - t0
    sleep_time = frame_duration - elapsed
    if sleep_time > 0:
        time.sleep(sleep_time)
```

## 六、前端设计

### 6.1 页面结构

文件：`static/index.html`（本地编写，SFTP 上传到 `~/workplace/fft/static/`）

```
┌───────────────────────────────────────────────────────┐
│  XDMA FFT 音乐频谱分析仪                              │
├───────────────────────────────────────────────────────┤
│                                                       │
│  ┌───────────────────────────────────────────────┐   │
│  │              Canvas 频谱柱状图                  │   │
│  │   Y轴: 幅度 (归一化 0~1)                       │   │
│  │   X轴: 频率 bin (0 ~ 512)                     │   │
│  │   柱状图，每个 bin 一根柱子                     │   │
│  └───────────────────────────────────────────────┘   │
│                                                       │
│  状态: Connected | FPS: 43 | 帧计数: 12345           │
│  [选择MP3文件]  [开始]  [停止]                        │
└───────────────────────────────────────────────────────┘
```

### 6.2 Canvas 绘制逻辑

- 512 个频率 bin 对应 512 根柱子
- 柱宽 = canvas.width / 512
- 柱高 = normalized_magnitude × canvas.height
- 颜色渐变：低频偏蓝/绿，高频偏红/黄（HSL 色轮映射）
- 每帧清空画布并重绘

### 6.3 WebSocket 连接

```javascript
// 连接远程服务器（注意使用服务器 IP）
const ws = new WebSocket('ws://192.168.2.101:8000/ws/spectrum');
ws.onmessage = (event) => {
    const data = JSON.parse(event.data);
    drawSpectrum(data.bins);
};
```

## 七、运行方式

### 7.1 上传文件

通过 ssh-client SFTP 将本地 `prj/04/host/` 下所有文件上传到远程 `~/workplace/fft/`。

### 7.2 安装依赖

通过 ssh-client exec 执行：

```bash
cd ~/workplace/fft
pip3 install --user -r requirements.txt
sudo apt install ffmpeg -y   # pydub 依赖（如未安装）
```

### 7.3 上传 MP3 测试文件

通过 ssh-client SFTP 上传 MP3 文件到 `~/workplace/fft/`。

### 7.4 启动服务

通过 ssh-client exec 执行：

```bash
cd ~/workplace/fft
python3 fft_spectrum.py --mp3 ~/workplace/fft/test.mp3
# 服务器监听 0.0.0.0:8000
```

### 7.5 浏览器访问

本地浏览器打开 `http://192.168.2.101:8000`，即可看到实时频谱。

## 八、操作流程总结

```
本地 (Windows)                          远程 (192.168.2.101)
    │                                         │
    ├─ 编写 Python / HTML 代码                 │
    │                                         │
    ├─ SFTP upload ──────────────────→ ~/workplace/fft/
    │                                         │
    │                                 pip3 install -r requirements.txt
    │                                 python3 fft_spectrum.py --mp3 test.mp3
    │                                         │
    ├─ 浏览器 http://192.168.2.101:8000 ←──── Flask 服务
    │         WebSocket 实时频谱推送           │
```

## 九、验证标准

| 编号 | 验证项 | 通过条件 |
|------|--------|----------|
| P7-01 | MP3 解码 | 正确解码为 16-bit 单声道 44.1kHz PCM |
| P7-02 | DMA 帧传输 | 每帧 1024 × 16 bytes 写入/读回无错误 |
| P7-03 | WebSocket | 本地浏览器连接 192.168.2.101:8000 后实时接收频谱数据 |
| P7-04 | 频谱可视化 | 柱状图随音乐节奏实时变化 |
| P7-05 | 帧率 | 频谱更新率 ≈ 43 fps，画面流畅 |
| P7-06 | 长时间稳定性 | 连续播放 5 分钟以上无崩溃、无内存泄漏 |
| P7-07 | 正弦波校验 | 播放纯音测试文件，频谱在对应频率出现单峰 |
