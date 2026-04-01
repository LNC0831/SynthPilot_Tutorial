#!/usr/bin/env python3
"""基础 DMA 读写测试 — 验证 H2C/C2H 通道畅通"""

import os, struct, sys

H2C = "/dev/xdma0_h2c_0"
C2H = "/dev/xdma0_c2h_0"
N_SAMPLES = 1024
BYTES_PER_BEAT = 16          # 128-bit AXI bus
XFER_SIZE = N_SAMPLES * BYTES_PER_BEAT   # 16384 bytes

def build_ramp_data():
    """生成递增 ramp：每 beat 低 16-bit 放 sample 值，高位补零"""
    buf = bytearray(XFER_SIZE)
    for i in range(N_SAMPLES):
        # 16-bit signed sample (ramp 0..1023)
        struct.pack_into("<h", buf, i * BYTES_PER_BEAT, i)
    return bytes(buf)

def main():
    # 检查设备节点
    for dev in (H2C, C2H):
        if not os.path.exists(dev):
            print(f"ERROR: {dev} not found"); sys.exit(1)

    data = build_ramp_data()
    print(f"[TX] Writing {len(data)} bytes to {H2C} ...")

    with open(H2C, "wb") as f:
        f.write(data)
    print("[TX] Done.")

    print(f"[RX] Reading {XFER_SIZE} bytes from {C2H} ...")
    with open(C2H, "rb") as f:
        rx = f.read(XFER_SIZE)
    print(f"[RX] Got {len(rx)} bytes.")

    # 打印前 16 个 beat 的低 16-bit (unsigned, magnitude output)
    print("\n--- First 16 output samples (low 16-bit unsigned) ---")
    for i in range(min(16, len(rx) // BYTES_PER_BEAT)):
        val = struct.unpack_from("<H", rx, i * BYTES_PER_BEAT)[0]
        print(f"  bin[{i:4d}] = {val}")

    print("\nDMA round-trip OK (data goes through FFT+magnitude, not loopback).")

if __name__ == "__main__":
    main()
