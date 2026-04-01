#!/usr/bin/env python3
"""XDMA FFT 音乐频谱分析仪 — Flask + WebSocket 实时可视化"""

import argparse
import json
import os
import struct
import sys
import threading
import time

import numpy as np
from pydub import AudioSegment
from flask import Flask, send_from_directory, send_file
from flask_sock import Sock

# ── 常量 ───────────────────────────────────────────────────

H2C_DEV = "/dev/xdma0_h2c_0"
C2H_DEV = "/dev/xdma0_c2h_0"
N = 1024                    # FFT 点数
BYTES_PER_BEAT = 16         # 128-bit AXI
XFER_SIZE = N * BYTES_PER_BEAT
SAMPLE_RATE = 44100
FRAME_DURATION = N / SAMPLE_RATE  # ≈ 23.2 ms
REF_AMPLITUDE = 4096.0      # 0 dB 参考值（满幅正弦的典型 FFT 幅度）
DB_FLOOR = -72.0            # 最低显示 dB

# ── 全局状态 ───────────────────────────────────────────────

app = Flask(__name__, static_folder="static")
sock = Sock(app)

latest_spectrum = None
spectrum_lock = threading.Lock()
playback_done = False
mp3_path_global = None
client_ready = threading.Event()  # 浏览器音频就绪后触发


# ── 音频处理 ───────────────────────────────────────────────

def load_audio(mp3_path):
    """MP3 → 16-bit mono 44.1kHz PCM numpy array"""
    audio = AudioSegment.from_file(mp3_path)
    audio = audio.set_channels(1)
    audio = audio.set_sample_width(2)
    audio = audio.set_frame_rate(SAMPLE_RATE)
    pcm = np.frombuffer(audio.raw_data, dtype=np.int16)
    return pcm


def frame_generator(pcm, frame_size=N):
    for i in range(0, len(pcm) - frame_size + 1, frame_size):
        yield pcm[i : i + frame_size]


# ── DMA 传输 ───────────────────────────────────────────────

def dma_process_frame(h2c_fd, c2h_fd, frame):
    buf = bytearray(XFER_SIZE)
    for i in range(N):
        struct.pack_into("<h", buf, i * BYTES_PER_BEAT, int(frame[i]))

    h2c_fd.seek(0)
    h2c_fd.write(buf)

    c2h_fd.seek(0)
    raw = c2h_fd.read(XFER_SIZE)

    magnitudes = np.zeros(N, dtype=np.float32)
    for i in range(N):
        magnitudes[i] = struct.unpack_from("<H", raw, i * BYTES_PER_BEAT)[0]

    return magnitudes[:512]


# ── DMA 工作线程 ──────────────────────────────────────────

def dma_worker(pcm):
    global latest_spectrum, playback_done

    h2c_fd = open(H2C_DEV, "wb", buffering=0)
    c2h_fd = open(C2H_DEV, "rb", buffering=0)

    frame_count = 0
    total_frames = (len(pcm) - N + 1) // N
    print("[DMA] Waiting for browser audio ready...")
    client_ready.wait()
    print("[DMA] Starting playback: %d frames (%.1f seconds)" %
          (total_frames, total_frames * FRAME_DURATION))

    try:
        for frame in frame_generator(pcm):
            t0 = time.monotonic()
            spectrum = dma_process_frame(h2c_fd, c2h_fd, frame)

            # 转为 dB，归一化到 [0, 1]（DB_FLOOR~0dB → 0~1）
            eps = 1e-10
            db = 20.0 * np.log10(spectrum / REF_AMPLITUDE + eps)
            db_norm = np.clip((db - DB_FLOOR) / (-DB_FLOOR), 0.0, 1.0)

            with spectrum_lock:
                latest_spectrum = db_norm

            frame_count += 1
            if frame_count % 200 == 0:
                print("[DMA] Frame %d / %d" % (frame_count, total_frames))

            elapsed = time.monotonic() - t0
            sleep_time = FRAME_DURATION - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)
    finally:
        h2c_fd.close()
        c2h_fd.close()

    playback_done = True
    print("[DMA] Playback complete: %d frames" % frame_count)


# ── Flask 路由 ────────────────────────────────────────────

@app.route("/")
def index():
    return send_from_directory("static", "index.html")


@app.route("/audio")
def serve_audio():
    """提供原始音频文件供浏览器播放"""
    return send_file(mp3_path_global)


@sock.route("/ws/spectrum")
def spectrum_ws(ws):
    print("[WS] Client connected, waiting for 'start' signal...")
    # 等待浏览器发送 "start"（音频开始播放后发出）
    try:
        msg = ws.receive(timeout=30)
        if msg:
            data = json.loads(msg)
            if data.get("cmd") == "start":
                print("[WS] Browser audio playing, triggering DMA")
                client_ready.set()
    except Exception:
        pass

    try:
        while not playback_done:
            with spectrum_lock:
                spec = latest_spectrum

            if spec is not None:
                ws.send(json.dumps({"bins": spec.tolist()}))

            time.sleep(FRAME_DURATION)
    except Exception as e:
        print("[WS] Client disconnected: %s" % e)

    try:
        ws.send(json.dumps({"done": True}))
    except Exception:
        pass
    print("[WS] Sent done signal")


# ── Main ──────────────────────────────────────────────────

def main():
    global mp3_path_global

    parser = argparse.ArgumentParser(description="XDMA FFT Spectrum Analyzer")
    parser.add_argument("--mp3", "--audio", dest="mp3", required=True,
                        help="Path to audio file (MP3/FLAC/WAV/...)")
    parser.add_argument("--host", default="0.0.0.0", help="Listen host")
    parser.add_argument("--port", type=int, default=8000, help="Listen port")
    args = parser.parse_args()

    if not os.path.exists(args.mp3):
        print("ERROR: MP3 file not found: %s" % args.mp3)
        sys.exit(1)

    for dev in (H2C_DEV, C2H_DEV):
        if not os.path.exists(dev):
            print("ERROR: Device not found: %s" % dev)
            sys.exit(1)

    mp3_path_global = os.path.abspath(args.mp3)

    print("[AUDIO] Loading %s ..." % args.mp3)
    pcm = load_audio(args.mp3)
    print("[AUDIO] Loaded: %d samples, %.1f seconds" %
          (len(pcm), len(pcm) / SAMPLE_RATE))

    t = threading.Thread(target=dma_worker, args=(pcm,), daemon=True)
    t.start()

    print("[SERVER] http://%s:%d" % (args.host, args.port))
    app.run(host=args.host, port=args.port, threaded=True)


if __name__ == "__main__":
    main()
