
from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Depends, HTTPException
from typing import Dict, Set
from uuid import uuid4

router = APIRouter(prefix="/calls", tags=["calls"])

# In-memory rooms: { room_id: set(websocket) }
rooms: Dict[str, Set[WebSocket]] = {}

# (Optional) simple auth stub — plug your real auth later
def get_current_user_id():
    # TODO: use your real JWT auth. For now we allow everyone for MVP
    return "demo-user"

@router.post("/create")
def create_call_room():
    room_id = str(uuid4())
    rooms.setdefault(room_id, set())
    return {"room_id": room_id}

@router.websocket("/ws/{room_id}")
async def call_ws(ws: WebSocket, room_id: str):
    await ws.accept()

    # Room must exist (created via /calls/create)
    if room_id not in rooms:
        await ws.close(code=4001)
        return

    peers = rooms[room_id]
    peers.add(ws)

    try:
        while True:
            msg = await ws.receive_text()
            # Relay to all other peers in the same room
            dead = []
            for p in list(peers):
                if p is not ws:
                    try:
                        await p.send_text(msg)
                    except WebSocketDisconnect:
                        dead.append(p)
            for d in dead:
                peers.discard(d)
    except WebSocketDisconnect:
        pass
    finally:
        peers.discard(ws)
        if not peers:
            rooms.pop(room_id, None)
