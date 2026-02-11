"""Unit tests for server.streamer module.

Tests use real temporary files (via ``tmp_path``) to simulate the
typescript log file that btb produces.  WebSocket clients are simulated
using lightweight async mock objects that record sent data.
"""

import asyncio
from pathlib import Path
from typing import Optional
from unittest.mock import AsyncMock, MagicMock

import pytest

from server.streamer import TUIStreamer, TUIStreamerManager


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


class FakeWebSocket:
    """Minimal fake WebSocket that records binary messages sent to it.

    Optionally raises on ``send_bytes`` to simulate a disconnected client.
    """

    def __init__(self, *, fail_on_send: bool = False) -> None:
        self.sent: list[bytes] = []
        self._fail_on_send = fail_on_send

    async def send_bytes(self, data: bytes) -> None:
        if self._fail_on_send:
            raise ConnectionResetError("client gone")
        self.sent.append(data)

    @property
    def all_data(self) -> bytes:
        return b"".join(self.sent)


# ---------------------------------------------------------------------------
# TUIStreamer — buffer accumulation
# ---------------------------------------------------------------------------


class TestBufferAccumulation:
    """Verify that the streamer accumulates all data from the file."""

    def test_buffer_starts_empty(self, tmp_path):
        ts_path = str(tmp_path / "typescript.log")
        streamer = TUIStreamer("job-1", ts_path)
        assert streamer.buffer == b""

    def test_stream_loop_reads_file_data(self, tmp_path):
        """stream_loop reads data written to the typescript file."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"hello world")

        streamer = TUIStreamer("job-1", str(ts_path))

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            # Give the loop time to read
            await asyncio.sleep(0.5)
            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        assert b"hello world" in streamer.buffer

    def test_buffer_accumulates_incremental_writes(self, tmp_path):
        """Data written in multiple chunks is fully accumulated."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"")

        streamer = TUIStreamer("job-1", str(ts_path))

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.3)

            # Write first chunk
            with open(ts_path, "ab") as f:
                f.write(b"chunk1-")
            await asyncio.sleep(0.4)

            # Write second chunk
            with open(ts_path, "ab") as f:
                f.write(b"chunk2")
            await asyncio.sleep(0.4)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        assert b"chunk1-" in streamer.buffer
        assert b"chunk2" in streamer.buffer

    def test_buffer_includes_ansi_codes(self, tmp_path):
        """Raw ANSI escape codes are preserved in the buffer."""
        ts_path = tmp_path / "typescript.log"
        ansi_data = b"\x1b[32mGREEN\x1b[0m normal"
        ts_path.write_bytes(ansi_data)

        streamer = TUIStreamer("job-1", str(ts_path))

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.5)
            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        assert ansi_data in streamer.buffer


# ---------------------------------------------------------------------------
# TUIStreamer — late-join catchup
# ---------------------------------------------------------------------------


class TestLateJoinCatchup:
    """Verify that clients connecting after data is buffered get the full history."""

    def test_late_join_receives_full_buffer(self, tmp_path):
        """A client that connects after data is written gets the full buffer."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"pre-existing data")

        streamer = TUIStreamer("job-1", str(ts_path))
        ws = FakeWebSocket()

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.5)

            # Client joins after data is already buffered
            await streamer.add_client(ws)
            await asyncio.sleep(0.1)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        assert ws.all_data == b"pre-existing data"

    def test_late_join_then_new_data(self, tmp_path):
        """A late-joining client gets the buffer AND subsequent new data."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"old-")

        streamer = TUIStreamer("job-1", str(ts_path))
        ws = FakeWebSocket()

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.5)

            await streamer.add_client(ws)
            await asyncio.sleep(0.1)

            # Write new data after client joined
            with open(ts_path, "ab") as f:
                f.write(b"new")
            await asyncio.sleep(0.5)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        # First message is catchup, subsequent messages are new data
        assert ws.all_data == b"old-new"


# ---------------------------------------------------------------------------
# TUIStreamer — broadcast to multiple clients
# ---------------------------------------------------------------------------


class TestBroadcast:
    """Verify that data is broadcast to all connected clients."""

    def test_broadcast_to_multiple_clients(self, tmp_path):
        """All connected clients receive the same data."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"")

        streamer = TUIStreamer("job-1", str(ts_path))
        ws1 = FakeWebSocket()
        ws2 = FakeWebSocket()
        ws3 = FakeWebSocket()

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.3)

            await streamer.add_client(ws1)
            await streamer.add_client(ws2)
            await streamer.add_client(ws3)

            with open(ts_path, "ab") as f:
                f.write(b"broadcast-data")
            await asyncio.sleep(0.5)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        assert ws1.all_data == b"broadcast-data"
        assert ws2.all_data == b"broadcast-data"
        assert ws3.all_data == b"broadcast-data"

    def test_broadcast_preserves_chunk_order(self, tmp_path):
        """Multiple chunks are received in order by all clients."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"")

        streamer = TUIStreamer("job-1", str(ts_path))
        ws1 = FakeWebSocket()
        ws2 = FakeWebSocket()

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.3)

            await streamer.add_client(ws1)
            await streamer.add_client(ws2)

            with open(ts_path, "ab") as f:
                f.write(b"AAA")
            await asyncio.sleep(0.5)

            with open(ts_path, "ab") as f:
                f.write(b"BBB")
            await asyncio.sleep(0.5)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        assert b"AAA" in ws1.all_data
        assert b"BBB" in ws1.all_data
        assert ws1.all_data.index(b"AAA") < ws1.all_data.index(b"BBB")
        assert ws2.all_data == ws1.all_data


# ---------------------------------------------------------------------------
# TUIStreamer — client disconnect
# ---------------------------------------------------------------------------


class TestClientDisconnect:
    """Verify that disconnected clients are handled gracefully."""

    def test_remove_client_decreases_count(self, tmp_path):
        """Removing a client decreases the client count."""
        ts_path = str(tmp_path / "typescript.log")
        streamer = TUIStreamer("job-1", ts_path)
        ws = FakeWebSocket()

        async def run():
            await streamer.add_client(ws)
            assert streamer.client_count == 1
            await streamer.remove_client(ws)
            assert streamer.client_count == 0

        asyncio.get_event_loop().run_until_complete(run())

    def test_remove_nonexistent_client_is_noop(self, tmp_path):
        """Removing a client that was never added does not raise."""
        ts_path = str(tmp_path / "typescript.log")
        streamer = TUIStreamer("job-1", ts_path)
        ws = FakeWebSocket()

        async def run():
            await streamer.remove_client(ws)
            assert streamer.client_count == 0

        asyncio.get_event_loop().run_until_complete(run())

    def test_failed_client_removed_during_broadcast(self, tmp_path):
        """A client that errors on send is removed during broadcast."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"")

        streamer = TUIStreamer("job-1", str(ts_path))
        good_ws = FakeWebSocket()
        bad_ws = FakeWebSocket(fail_on_send=True)

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.3)

            await streamer.add_client(good_ws)
            # bad_ws will fail on catchup send, but since buffer is empty
            # it won't fail yet — add it directly to the set
            streamer._clients.add(bad_ws)
            assert streamer.client_count == 2

            with open(ts_path, "ab") as f:
                f.write(b"test-data")
            await asyncio.sleep(0.5)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        # bad_ws should have been removed
        assert streamer.client_count == 1
        assert good_ws.all_data == b"test-data"

    def test_disconnect_does_not_affect_other_clients(self, tmp_path):
        """Removing one client does not affect data delivery to others."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"")

        streamer = TUIStreamer("job-1", str(ts_path))
        ws1 = FakeWebSocket()
        ws2 = FakeWebSocket()

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.3)

            await streamer.add_client(ws1)
            await streamer.add_client(ws2)

            with open(ts_path, "ab") as f:
                f.write(b"before-")
            await asyncio.sleep(0.5)

            # Remove ws1
            await streamer.remove_client(ws1)

            with open(ts_path, "ab") as f:
                f.write(b"after")
            await asyncio.sleep(0.5)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        # ws1 got data before disconnect only
        assert b"before-" in ws1.all_data
        # ws2 got all data
        assert b"before-" in ws2.all_data
        assert b"after" in ws2.all_data


# ---------------------------------------------------------------------------
# TUIStreamer — stop behavior
# ---------------------------------------------------------------------------


class TestStopBehavior:
    """Verify that the streamer stops cleanly."""

    def test_stop_sets_flag(self, tmp_path):
        ts_path = str(tmp_path / "typescript.log")
        streamer = TUIStreamer("job-1", ts_path)
        assert streamer.is_stopped is False
        streamer.stop()
        assert streamer.is_stopped is True

    def test_stream_loop_exits_after_stop(self, tmp_path):
        """stream_loop exits promptly after stop() is called."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"data")

        streamer = TUIStreamer("job-1", str(ts_path))

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.5)
            streamer.stop()
            # Should exit within a few poll intervals
            await asyncio.wait_for(loop_task, timeout=2.0)

        asyncio.get_event_loop().run_until_complete(run())

    def test_stream_loop_waits_for_file(self, tmp_path):
        """stream_loop waits for the file to appear before reading."""
        ts_path = tmp_path / "typescript.log"
        # File does not exist yet

        streamer = TUIStreamer("job-1", str(ts_path))

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.5)

            # Create the file after a delay
            ts_path.write_bytes(b"delayed-data")
            await asyncio.sleep(0.5)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        assert b"delayed-data" in streamer.buffer

    def test_continues_without_clients(self, tmp_path):
        """The streamer continues buffering even with no clients."""
        ts_path = tmp_path / "typescript.log"
        ts_path.write_bytes(b"")

        streamer = TUIStreamer("job-1", str(ts_path))

        async def run():
            loop_task = asyncio.create_task(streamer.stream_loop())
            await asyncio.sleep(0.3)

            # No clients connected — write data
            with open(ts_path, "ab") as f:
                f.write(b"no-clients-data")
            await asyncio.sleep(0.5)

            streamer.stop()
            await loop_task

        asyncio.get_event_loop().run_until_complete(run())
        assert b"no-clients-data" in streamer.buffer


# ---------------------------------------------------------------------------
# TUIStreamerManager
# ---------------------------------------------------------------------------


class TestTUIStreamerManager:
    """Tests for the TUIStreamerManager class."""

    def test_get_or_create_new(self, tmp_path):
        """get_or_create creates a new streamer for an unknown job."""
        manager = TUIStreamerManager()
        ts_path = str(tmp_path / "typescript.log")
        streamer = manager.get_or_create("job-1", ts_path)
        assert isinstance(streamer, TUIStreamer)
        assert streamer.job_id == "job-1"
        assert manager.active_count == 1

    def test_get_or_create_returns_existing(self, tmp_path):
        """get_or_create returns the same streamer for the same job."""
        manager = TUIStreamerManager()
        ts_path = str(tmp_path / "typescript.log")
        s1 = manager.get_or_create("job-1", ts_path)
        s2 = manager.get_or_create("job-1", ts_path)
        assert s1 is s2
        assert manager.active_count == 1

    def test_get_existing(self, tmp_path):
        """get returns the streamer if it exists."""
        manager = TUIStreamerManager()
        ts_path = str(tmp_path / "typescript.log")
        created = manager.get_or_create("job-1", ts_path)
        found = manager.get("job-1")
        assert found is created

    def test_get_nonexistent_returns_none(self):
        """get returns None for an unknown job."""
        manager = TUIStreamerManager()
        assert manager.get("nonexistent") is None

    def test_remove_stops_and_removes(self, tmp_path):
        """remove stops the streamer and removes it from the manager."""
        manager = TUIStreamerManager()
        ts_path = str(tmp_path / "typescript.log")
        streamer = manager.get_or_create("job-1", ts_path)
        assert not streamer.is_stopped

        manager.remove("job-1")
        assert streamer.is_stopped
        assert manager.get("job-1") is None
        assert manager.active_count == 0

    def test_remove_nonexistent_is_noop(self):
        """remove for an unknown job does not raise."""
        manager = TUIStreamerManager()
        manager.remove("nonexistent")  # Should not raise

    def test_multiple_streamers(self, tmp_path):
        """Manager can handle multiple concurrent streamers."""
        manager = TUIStreamerManager()
        s1 = manager.get_or_create("job-1", str(tmp_path / "ts1.log"))
        s2 = manager.get_or_create("job-2", str(tmp_path / "ts2.log"))
        s3 = manager.get_or_create("job-3", str(tmp_path / "ts3.log"))

        assert manager.active_count == 3
        assert manager.get("job-1") is s1
        assert manager.get("job-2") is s2
        assert manager.get("job-3") is s3

        manager.remove("job-2")
        assert manager.active_count == 2
        assert manager.get("job-2") is None
        assert manager.get("job-1") is s1
        assert manager.get("job-3") is s3
