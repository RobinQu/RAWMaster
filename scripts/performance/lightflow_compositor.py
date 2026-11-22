"""Capture Chromium compositor swaps from a standalone headless-shell page."""

import base64
from io import BytesIO
import json
import threading
import time

from PIL import Image
import websocket


def clock_anchor():
    """Measure realtime minus monotonic using the smallest bracketing interval."""
    samples = []
    for _ in range(12):
        before = time.monotonic_ns()
        epoch = time.time_ns()
        after = time.monotonic_ns()
        samples.append((after - before, epoch - (before + after) // 2))
    bracket, offset = min(samples)
    return {"realtimeMinusMonotonicNs": offset, "bracketNs": bracket}


class CompositorStream:
    def __init__(self, endpoint, transport):
        self.socket = websocket.create_connection(
            endpoint, suppress_origin=True, timeout=1
        )
        self.first = threading.Event()
        self.closed = threading.Event()
        self.frames = []
        self.failure = None
        self.anchor = clock_anchor()
        self.next_id = 2
        self.transport = transport

    def __enter__(self):
        self.socket.send(
            json.dumps(
                {
                    "id": 1,
                    "method": "Page.startScreencast",
                    "params": {
                        "format": "png", "everyNthFrame": 1,
                        "maxWidth": self.transport[0], "maxHeight": self.transport[1],
                    },
                }
            )
        )
        self.thread = threading.Thread(target=self._collect, daemon=True)
        self.thread.start()
        if not self.first.wait(timeout=8) or self.failure:
            self.close()
            raise ValueError(
                self.failure or "Chromium supplied no initial compositor swap"
            )
        return self

    def _collect(self):
        try:
            while not self.closed.is_set():
                try:
                    message = json.loads(self.socket.recv())
                except websocket.WebSocketTimeoutException:
                    continue
                if message.get("id") == 1 and "error" in message:
                    raise ValueError(message["error"]["message"])
                if message.get("method") != "Page.screencastFrame":
                    continue
                frame = message["params"]
                received = time.monotonic_ns()
                self.socket.send(
                    json.dumps(
                        {
                            "id": self.next_id,
                            "method": "Page.screencastFrameAck",
                            "params": {"sessionId": frame["sessionId"]},
                        }
                    )
                )
                self.next_id += 1
                stamp = (
                    round(frame["metadata"]["timestamp"] * 1_000_000_000)
                    - self.anchor["realtimeMinusMonotonicNs"]
                )
                if not 0 <= received - stamp <= 5_000_000_000:
                    raise ValueError(
                        "Compositor swap timestamp is outside the calibrated host-clock interval"
                    )
                if self.frames and stamp <= self.frames[-1][0]:
                    continue
                # Decode PNG only after the timed action series. Ack immediately to limit dropped swaps.
                self.frames.append((stamp, received, frame["data"]))
                self.first.set()
        except Exception as exc:
            if not self.closed.is_set():
                self.failure = str(exc)
                self.first.set()

    def close(self):
        if self.closed.is_set():
            return
        self.closed.set()
        self.socket.close()
        self.thread.join(timeout=2)

    def __exit__(self, *args):
        self.close()

    def signatures(self, roi, viewport):
        if self.failure:
            raise ValueError(self.failure)
        scale_x, scale_y = self.transport[0] / viewport[0], self.transport[1] / viewport[1]
        left, top, width, height = [v * s for v, s in zip(roi, (scale_x, scale_y, scale_x, scale_y))]
        frames, delivery = [], []
        for stamp, receipt, encoded in self.frames:
            with Image.open(BytesIO(base64.b64decode(encoded, validate=True))) as image:
                if list(image.size) != list(self.transport):
                    raise ValueError(
                        f"Compositor transport raster {image.size} differs from requested {self.transport}"
                    )
                rgb = image.convert("RGB")
                grid = bytearray()
                for y in range(64):
                    row = min(rgb.height - 1, int(top + height * (y + 0.5) / 64))
                    for x in range(96):
                        col = min(rgb.width - 1, int(left + width * (x + 0.5) / 96))
                        grid.extend(rgb.getpixel((col, row)))
            frames.append((stamp, bytes(grid)))
            delivery.append(round((receipt - stamp) / 1_000_000, 3))
        return frames, delivery
