"""The window: one row per aircraft on top, every trusted message below.

Qt runs only the display. The receiver works in its own threads (engine.py),
and a timer collects from it four times a second, so a slow repaint can never
back up into the sample stream.
"""

import time

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QBrush, QColor, QFontDatabase
from PyQt6.QtWidgets import (QApplication, QCheckBox, QDoubleSpinBox, QHBoxLayout,
                             QHeaderView, QLabel, QMainWindow, QMessageBox,
                             QPlainTextEdit, QPushButton, QSplitter, QTableWidget,
                             QTableWidgetItem, QVBoxLayout, QWidget)

from engine import log_line

COLUMNS = [("ICAO", "icao"), ("Callsign", "callsign"), ("Squawk", "squawk"),
           ("Altitude ft", "altitude"), ("Speed kt", "speed"), ("Track °", "track"),
           ("V/S fpm", "vrate"), ("Latitude", "lat"), ("Longitude", "lon"),
           ("Msgs", "messages"), ("Signal dBFS", "rssi"), ("Age s", "age")]
STALE = 30.0          # rows older than this are greyed; the tracker drops them at 60


class Num(QTableWidgetItem):
    """Sorts by value, not by text, and puts blanks last."""

    def __init__(self, value, text):
        super().__init__(text)
        self.value = value
        self.setTextAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)

    def __lt__(self, other):
        a, b = self.value, getattr(other, "value", None)
        if a is None:
            return False
        if b is None:
            return True
        return a < b


class Window(QMainWindow):
    def __init__(self, rx, rb, describe, status_line, args):
        super().__init__()
        self.rx, self.rb, self.status_line = rx, rb, status_line
        self.board = rb["uri"].startswith("ip:") or rb["uri"].startswith("usb:")
        self.setWindowTitle("ADS-B - Fishball7020")
        self.resize(1200, 760)
        mono = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)

        top = QHBoxLayout()
        self.source_label = QLabel(describe(rb))
        top.addWidget(self.source_label, 1)
        self.gain = QDoubleSpinBox()
        self.gain.setRange(-3, 71)
        self.gain.setSingleStep(1)
        self.gain.setSuffix(" dB")
        self.gain.setKeyboardTracking(False)
        self.agc = QCheckBox("AGC")
        if self.board:
            self.gain.setValue(rb.get("gain_db") or 0)
            self.agc.setChecked(rb.get("gain_mode") != "manual")
            self.gain.setEnabled(not self.agc.isChecked())
            self.gain.valueChanged.connect(self.set_gain)
            self.agc.toggled.connect(self.set_agc)
            top.addWidget(QLabel(f"RX{rb['channel']} gain"))
            top.addWidget(self.gain)
            top.addWidget(self.agc)
        self.only_sel = QCheckBox("Log: selected aircraft only")
        self.pause = QCheckBox("Pause log")
        clear = QPushButton("Clear log")
        top.addWidget(self.only_sel)
        top.addWidget(self.pause)
        top.addWidget(clear)

        self.table = QTableWidget(0, len(COLUMNS))
        self.table.setHorizontalHeaderLabels([c[0] for c in COLUMNS])
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setSortingEnabled(True)
        self.table.sortByColumn(COLUMNS.index(("Age s", "age")), Qt.SortOrder.AscendingOrder)
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self.table.setFont(mono)

        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(5000)
        self.log.setFont(mono)
        self.log.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        clear.clicked.connect(self.log.clear)

        split = QSplitter(Qt.Orientation.Vertical)
        split.addWidget(self.table)
        split.addWidget(self.log)
        split.setSizes([420, 300])

        lay = QVBoxLayout()
        lay.addLayout(top)
        lay.addWidget(split, 1)
        w = QWidget()
        w.setLayout(lay)
        self.setCentralWidget(w)
        self.status = QLabel()
        self.statusBar().addPermanentWidget(self.status, 1)

        self.timer = QTimer(self)
        self.timer.timeout.connect(self.tick)
        self.timer.start(250)
        self.end = time.time() + args.seconds if args.seconds else None
        self._reported = False

    # -- receiver controls (live: a gain change needs no stream restart) ------

    def set_gain(self, v):
        try:
            got = self.rx.source.set_gain(v)
            self.statusBar().showMessage(f"gain reads back {got:g} dB", 4000)
        except Exception as e:                          # noqa: BLE001
            self.statusBar().showMessage(f"gain not set: {e}", 8000)

    def set_agc(self, on):
        self.gain.setEnabled(not on)
        try:
            self.rx.source.set_gain("agc" if on else self.gain.value())
        except Exception as e:                          # noqa: BLE001
            self.statusBar().showMessage(f"gain mode not set: {e}", 8000)

    # -- the four-times-a-second refresh -------------------------------------

    def selected_icao(self):
        rows = self.table.selectionModel().selectedRows()
        if not rows:
            return None
        item = self.table.item(rows[0].row(), 0)
        return int(item.text(), 16) if item else None

    def tick(self):
        now = time.time()
        entries = self.rx.drain_log()
        if entries and not self.pause.isChecked():
            sel = self.selected_icao() if self.only_sel.isChecked() else None
            lines = [log_line(e) for e in entries if sel is None or e[3] == sel]
            if lines:
                self.log.appendPlainText("\n".join(lines))
        rows, stats = self.rx.snapshot()
        self.fill(rows, now)
        if self.board and self.agc.isChecked():
            try:
                self.gain.blockSignals(True)
                self.gain.setValue(self.rx.source.read_gain())
            except Exception:                           # noqa: BLE001
                pass
            finally:
                self.gain.blockSignals(False)
        self.status.setText(f"{len(rows)} aircraft   " + self.status_line(stats))
        if self.rx.error and not self._reported:
            self._reported = True
            QMessageBox.warning(self, "ADS-B receiver stopped", self.rx.error)
        if self.end and now >= self.end:
            self.close()

    def fill(self, rows, now):
        sel = self.selected_icao()
        self.table.setSortingEnabled(False)
        self.table.setRowCount(len(rows))
        for i, r in enumerate(rows):
            age = now - r["last_seen"]
            vals = dict(r, age=age)
            for j, (_, key) in enumerate(COLUMNS):
                v = vals[key]
                if key == "icao":
                    item = QTableWidgetItem(f"{v:06X}")
                elif key in ("callsign", "squawk"):
                    item = QTableWidgetItem(v or "")
                else:
                    fmt = {"lat": "{:.4f}", "lon": "{:.4f}", "rssi": "{:.1f}",
                           "age": "{:.0f}", "track": "{:.1f}", "vrate": "{:+d}"}.get(key, "{}")
                    text = "" if v is None else fmt.format(v)
                    if key == "speed" and v is not None and r["speed_kind"] not in (None, "GS"):
                        text += f" {r['speed_kind']}"
                    item = Num(v, text)
                if age > STALE:
                    item.setForeground(QBrush(QColor(140, 140, 140)))
                self.table.setItem(i, j, item)
        self.table.setSortingEnabled(True)
        if sel is not None:
            for i in range(self.table.rowCount()):
                if self.table.item(i, 0).text() == f"{sel:06X}":
                    self.table.selectRow(i)
                    break

    def closeEvent(self, ev):
        self.timer.stop()
        self.rx.close()
        super().closeEvent(ev)


def run(args, make_receiver, describe, status_line):
    app = QApplication.instance() or QApplication([])
    rx, rb = make_receiver(args)
    w = Window(rx, rb, describe, status_line, args)
    w.show()
    return app.exec()
