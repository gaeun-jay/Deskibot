from collections import defaultdict

from fastapi import WebSocket


class ConnectionManager:
    def __init__(self):
        self._connections: dict[str, set[WebSocket]] = defaultdict(set)

    async def connect(
        self,
        user_id: str,
        websocket: WebSocket,
    ):
        self._connections[user_id].add(websocket)

    def disconnect(
        self,
        user_id: str,
        websocket: WebSocket,
    ):
        connections = self._connections.get(user_id)

        if not connections:
            return

        connections.discard(websocket)

        if not connections:
            self._connections.pop(user_id, None)

    async def broadcast(
        self,
        user_id: str,
        message: dict,
        exclude: WebSocket | None = None,
    ):
        connections = list(
            self._connections.get(user_id, set())
        )

        disconnected = []

        for connection in connections:
            if connection is exclude:
                continue

            try:
                await connection.send_json(message)
            except Exception:
                disconnected.append(connection)

        for connection in disconnected:
            self.disconnect(user_id, connection)


manager = ConnectionManager()