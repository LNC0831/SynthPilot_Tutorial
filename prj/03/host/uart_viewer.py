"""FPGA UART Data Visualizer

Real-time waveform display for multi-clock domain data acquisition system.
Receives incrementing counter data (0-255) via UART and displays as scrolling sawtooth wave.
"""

import sys
import collections

import serial
import serial.tools.list_ports
from PyQt6.QtCore import Qt, QThread, pyqtSignal, QTimer
from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QComboBox, QPushButton, QStatusBar,
)
import pyqtgraph as pg


WINDOW_SIZE = 1000  # number of data points in scrolling view


class SerialWorker(QThread):
    """Background thread that reads bytes from the serial port."""

    data_received = pyqtSignal(bytes)
    error_occurred = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        self._running = False
        self.ser = None

    def open(self, port, baudrate=115200):
        self.ser = serial.Serial(port, baudrate, timeout=0.05)
        self._running = True

    def run(self):
        while self._running:
            try:
                data = self.ser.read(256)
                if data:
                    self.data_received.emit(data)
            except Exception as e:
                self.error_occurred.emit(str(e))
                break

    def stop(self):
        self._running = False
        self.wait(2000)
        if self.ser and self.ser.is_open:
            self.ser.close()
            self.ser = None


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("UART Data Visualizer")
        self.resize(900, 520)

        # State
        self.buffer = collections.deque(maxlen=WINDOW_SIZE)
        self.total_bytes = 0
        self.error_count = 0
        self.last_byte = None
        self.worker = None

        self._build_ui()
        self._refresh_ports()

        # Plot update timer (30 fps)
        self._plot_timer = QTimer()
        self._plot_timer.timeout.connect(self._update_plot)
        self._dirty = False

    # ── UI ──────────────────────────────────────────────

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)

        # Top bar: port selector + controls
        top = QHBoxLayout()
        top.addWidget(QLabel("Port:"))
        self.port_combo = QComboBox()
        self.port_combo.setMinimumWidth(160)
        top.addWidget(self.port_combo)

        top.addWidget(QLabel("Baud:"))
        self.baud_combo = QComboBox()
        self.baud_combo.addItems(["115200", "9600", "19200", "38400", "57600"])
        top.addWidget(self.baud_combo)

        self.refresh_btn = QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self._refresh_ports)
        top.addWidget(self.refresh_btn)

        self.open_btn = QPushButton("Open")
        self.open_btn.clicked.connect(self._open_serial)
        top.addWidget(self.open_btn)

        self.close_btn = QPushButton("Close")
        self.close_btn.setEnabled(False)
        self.close_btn.clicked.connect(self._close_serial)
        top.addWidget(self.close_btn)

        top.addStretch()
        layout.addLayout(top)

        # Plot
        pg.setConfigOptions(antialias=False)
        self.plot_widget = pg.PlotWidget()
        self.plot_widget.setLabel("left", "Byte Value")
        self.plot_widget.setLabel("bottom", "Sample Index")
        self.plot_widget.setYRange(0, 255)
        self.plot_widget.showGrid(x=True, y=True, alpha=0.3)
        self.curve = self.plot_widget.plot(pen=pg.mkPen("c", width=1))
        layout.addWidget(self.plot_widget)

        # Status bar
        self.status_received = QLabel("Received: 0")
        self.status_errors = QLabel("Errors: 0")
        self.status_current = QLabel("Current: --")
        sb = QStatusBar()
        sb.addPermanentWidget(self.status_received)
        sb.addPermanentWidget(self.status_errors)
        sb.addPermanentWidget(self.status_current)
        self.setStatusBar(sb)

    def _refresh_ports(self):
        self.port_combo.clear()
        for p in serial.tools.list_ports.comports():
            self.port_combo.addItem(f"{p.device}  {p.description}", p.device)

    # ── Serial control ──────────────────────────────────

    def _open_serial(self):
        port = self.port_combo.currentData()
        baud = int(self.baud_combo.currentText())
        if not port:
            return

        self.worker = SerialWorker()
        try:
            self.worker.open(port, baud)
        except Exception as e:
            self.statusBar().showMessage(f"Error: {e}", 5000)
            return

        self.worker.data_received.connect(self._on_data)
        self.worker.error_occurred.connect(self._on_error)
        self.worker.start()

        self._plot_timer.start(33)  # ~30 fps

        self.open_btn.setEnabled(False)
        self.close_btn.setEnabled(True)
        self.port_combo.setEnabled(False)
        self.baud_combo.setEnabled(False)

        # Reset counters
        self.buffer.clear()
        self.total_bytes = 0
        self.error_count = 0
        self.last_byte = None

    def _close_serial(self):
        self._plot_timer.stop()
        if self.worker:
            self.worker.stop()
            self.worker = None

        self.open_btn.setEnabled(True)
        self.close_btn.setEnabled(False)
        self.port_combo.setEnabled(True)
        self.baud_combo.setEnabled(True)

    # ── Data handling ───────────────────────────────────

    def _on_data(self, data: bytes):
        for b in data:
            self.total_bytes += 1
            self.buffer.append(b)

            # Integrity check: expect (prev + 1) % 256
            if self.last_byte is not None:
                if b != (self.last_byte + 1) % 256:
                    self.error_count += 1
            self.last_byte = b

        self._dirty = True

        # Update status labels (lightweight, every packet)
        self.status_received.setText(f"Received: {self.total_bytes}")
        self.status_errors.setText(f"Errors: {self.error_count}")
        self.status_current.setText(f"Current: 0x{self.last_byte:02X}")

    def _update_plot(self):
        if not self._dirty:
            return
        self._dirty = False
        if self.buffer:
            self.curve.setData(list(self.buffer))

    def _on_error(self, msg):
        self.statusBar().showMessage(f"Serial error: {msg}", 5000)
        self._close_serial()

    def closeEvent(self, event):
        self._close_serial()
        event.accept()


def main():
    app = QApplication(sys.argv)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
