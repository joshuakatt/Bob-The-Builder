"""TUI Streamer for the BTB Service.

Streams btb's terminal output (captured by the ``script`` command into a
typescript log file) to browser clients over WebSocket connections.

The streamer tails the typescript file using asyncio, accumulates a full
buffer for late-joining clients, and broadcasts new data chunks to all
connected WebSocket clients as binary messages (raw bytes with ANSI codes).

Two classes are provided:

- ``TUIStreamer`` — manages streaming for a single job
- ``TUIStreamerManager`` — manages multiple streamers (one per running job)
"""

import asyncio
import logging
from pathlib import Path
from typing import Optional

from aiohttp import web, WSMsgType

logger = logging.getLogger(__name__)

# How often (in seconds) the stream loop checks for new data
_POLL_INTERVAL = 0.2


class TUIStreamer:
    """Streams a single job's typescript log to WebSocket clients.

    The streamer tails the ``typescript.log`` file produced by the
    ``script`` command, accumulates all data into a buffer, and
    broadcasts new chunks to connected clients.  Late-joining clients
    receive the full buffer on connect so they see the complete history.

    Args:
        job_id: Unique identifier of the job being streamed.
        typescript_path: Path to the typescript log file to tail.
    """

    def __init__(self, job_id: str, typescript_path: str) -> None:
        self.job_id = job_id
        self.typescript_path = typescript_path
        self._clients: set[web.WebSocketResponse] = set()
        self._buffer = bytearray()
        self._stopped = False
        self._lock = asyncio.Lock()

    @property
    def client_count(self) -> int:
        """Return the number of currently connected clients."""
        return len(self._clients)

    @property
    def buffer(self) -> bytes:
        """Return a copy of the current buffer contents."""
        return bytes(self._buffer)

    async def add_client(self, ws: web.WebSocketResponse) -> None:
        """Add a WebSocket client and send the current buffer for catchup.

        The full accumulated buffer is sent immediately as a binary
        message so the client sees the complete terminal history.

        Args:
            ws: The WebSocket connection to add.
        """
        async with self._lock:
            self._clients.add(ws)
            # Send current buffer for catchup
            if self._buffer:
                try:
                    await ws.send_bytes(bytes(self._buffer))
                except (ConnectionResetError, Exception) as exc:
                    logger.warning(
                        "Failed to send catchup to client for job %s: %s",
                        self.job_id,
                        exc,
                    )
                    self._clients.discard(ws)

    async def remove_client(self, ws: web.WebSocketResponse) -> None:
        """Remove a WebSocket client from the set.

        Releases any resources associated with the client.  This does
        not affect the btb process or other connected clients.

        Args:
            ws: The WebSocket connection to remove.
        """
        async with self._lock:
            self._clients.discard(ws)
        logger.debug(
            "Removed client from job %s streamer (remaining: %d)",
            self.job_id,
            len(self._clients),
        )

    async def stream_loop(self) -> None:
        """Main loop that tails the typescript file and broadcasts data.

        Polls the file for new data every ``_POLL_INTERVAL`` seconds.
        New chunks are appended to the internal buffer and broadcast to
        all connected clients.  The loop continues even when no clients
        are connected (buffering data for late joiners).

        The loop exits when :meth:`stop` is called.  If the file does
        not yet exist, the loop waits for it to appear.
        """
        file_path = Path(self.typescript_path)
        offset = 0

        # Wait for the file to appear (btb may not have started yet)
        while not self._stopped and not file_path.exists():
            await asyncio.sleep(_POLL_INTERVAL)

        if self._stopped:
            return

        try:
            with open(file_path, "rb") as f:
                while not self._stopped:
                    f.seek(offset)
                    chunk = f.read()
                    if chunk:
                        offset += len(chunk)
                        self._buffer.extend(chunk)
                        await self._broadcast(chunk)
                    await asyncio.sleep(_POLL_INTERVAL)
        except Exception as exc:
            logger.error(
                "Error in stream loop for job %s: %s", self.job_id, exc
            )

        # Final read — pick up any data written between last poll and stop
        if file_path.exists():
            try:
                with open(file_path, "rb") as f:
                    f.seek(offset)
                    chunk = f.read()
                    if chunk:
                        self._buffer.extend(chunk)
                        await self._broadcast(chunk)
            except Exception:
                pass

    def stop(self) -> None:
        """Signal the stream loop to stop."""
        self._stopped = True

    @property
    def is_stopped(self) -> bool:
        """Return whether the streamer has been stopped."""
        return self._stopped

    async def _broadcast(self, data: bytes) -> None:
        """Send data to all connected clients.

        Clients that fail to receive the data are silently removed.

        Args:
            data: Raw bytes to send as a binary WebSocket message.
        """
        if not self._clients:
            return

        disconnected: list[web.WebSocketResponse] = []

        async with self._lock:
            for ws in list(self._clients):
                try:
                    await ws.send_bytes(data)
                except (ConnectionResetError, Exception) as exc:
                    logger.debug(
                        "Client disconnected during broadcast for job %s: %s",
                        self.job_id,
                        exc,
                    )
                    disconnected.append(ws)

            for ws in disconnected:
                self._clients.discard(ws)


class TUIStreamerManager:
    """Manages multiple TUI streamers, one per running job.

    Provides a simple interface to get or create streamers by job ID,
    and to clean up streamers when jobs complete.
    """

    def __init__(self) -> None:
        self._streamers: dict[str, TUIStreamer] = {}

    def get_or_create(self, job_id: str, typescript_path: str) -> TUIStreamer:
        """Return an existing streamer for the job, or create a new one.

        Args:
            job_id: Unique identifier of the job.
            typescript_path: Path to the typescript log file.

        Returns:
            The TUIStreamer instance for this job.
        """
        if job_id not in self._streamers:
            self._streamers[job_id] = TUIStreamer(job_id, typescript_path)
            logger.info("Created new TUI streamer for job %s", job_id)
        return self._streamers[job_id]

    def get(self, job_id: str) -> Optional[TUIStreamer]:
        """Return the streamer for a job, or None if not found.

        Args:
            job_id: Unique identifier of the job.

        Returns:
            The TUIStreamer instance, or None.
        """
        return self._streamers.get(job_id)

    def remove(self, job_id: str) -> None:
        """Stop and remove the streamer for a job.

        If no streamer exists for the given job ID, this is a no-op.

        Args:
            job_id: Unique identifier of the job.
        """
        streamer = self._streamers.pop(job_id, None)
        if streamer is not None:
            streamer.stop()
            logger.info("Removed TUI streamer for job %s", job_id)

    @property
    def active_count(self) -> int:
        """Return the number of active streamers."""
        return len(self._streamers)
