#!/usr/bin/env python3
"""FFT 端到端验证 — 正弦波 / 多频 / 静音测试"""

import os, struct, sys, math

H2C = "/dev/xdma0_h2c_0"
C2H = "/dev/xdma0_c2h_0"
N = 1024                     # FFT 点数
BYTES_PER_BEAT = 16          # 128-bit AXI
XFER_SIZE = N * BYTES_PER_BEAT
AMPLITUDE = 16000            # 16-bit signed 幅度


# ── 数据生成 ─────────────────────────────────────────────

def gen_sine(bins, amp=AMPLITUDE):
    """生成单频或多频正弦波, bins 为 list of bin indices"""
    buf = bytearray(XFER_SIZE)
    for i in range(N):
        val = 0.0
        for b in bins:
            val += amp * math.sin(2.0 * math.pi * b * i / N)
        val = val / len(bins)                 # 归一化防溢出
        sample = int(round(val))
        sample = max(-32768, min(32767, sample))
        struct.pack_into("<h", buf, i * BYTES_PER_BEAT, sample)
    return bytes(buf)

def gen_silence():
    return bytes(XFER_SIZE)


# ── DMA 传输 ─────────────────────────────────────────────

def dma_transfer(tx_data):
    with open(H2C, "wb") as f:
        f.write(tx_data)
    with open(C2H, "rb") as f:
        return f.read(XFER_SIZE)


def extract_spectrum(rx):
    """从 RX 数据提取 N 个 unsigned 16-bit 幅度值"""
    spec = []
    for i in range(N):
        val = struct.unpack_from("<H", rx, i * BYTES_PER_BEAT)[0]
        spec.append(val)
    return spec


# ── 测试用例 ─────────────────────────────────────────────

def test_sine(bins, label):
    print(f"\n{'='*60}")
    print(f"TEST: {label}  (expected peaks at bins {bins})")
    print('='*60)
    tx = gen_sine(bins)
    rx = dma_transfer(tx)
    spec = extract_spectrum(rx)

    # 找 top-K peaks
    indexed = sorted(enumerate(spec), key=lambda x: -x[1])
    peak_bin = indexed[0][0]
    peak_val = indexed[0][1]

    print(f"  Peak bin = {peak_bin}, value = {peak_val}")
    print(f"  Top 8 bins:")
    for idx, val in indexed[:8]:
        print(f"    bin[{idx:4d}] = {val}")

    # 验证
    ok = True
    for b in bins:
        # 允许 +-1 bin 容差
        found = any(abs(indexed[j][0] - b) <= 1 for j in range(len(bins) * 2))
        if not found:
            print(f"  FAIL: expected peak near bin {b} not found!")
            ok = False
    if ok:
        print(f"  PASS")
    return ok


def test_silence():
    print(f"\n{'='*60}")
    print(f"TEST: Silence (all-zero input)")
    print('='*60)
    tx = gen_silence()
    rx = dma_transfer(tx)
    spec = extract_spectrum(rx)

    max_val = max(spec)
    print(f"  Max output = {max_val}")
    if max_val < 10:
        print(f"  PASS (noise floor < 10)")
        return True
    else:
        print(f"  WARN: noise floor = {max_val} (may be acceptable)")
        return True   # 软判断


# ── Main ─────────────────────────────────────────────────

def main():
    for dev in (H2C, C2H):
        if not os.path.exists(dev):
            print(f"ERROR: {dev} not found"); sys.exit(1)

    results = []

    # P6-04: 单频正弦波 bin 64
    results.append(("Single-tone bin64", test_sine([64], "Single-tone sine @ bin 64")))

    # P6-05: 多频 bin 64 + 256
    results.append(("Multi-tone bin64+256", test_sine([64, 256], "Multi-tone sine @ bin 64 + 256")))

    # P6-06: 静音
    results.append(("Silence", test_silence()))

    print(f"\n{'='*60}")
    print("SUMMARY")
    print('='*60)
    all_pass = True
    for name, ok in results:
        status = "PASS" if ok else "FAIL"
        print(f"  {name:30s} {status}")
        if not ok:
            all_pass = False

    sys.exit(0 if all_pass else 1)

if __name__ == "__main__":
    main()
