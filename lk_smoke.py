import os, asyncio
from livekit import api

async def main():
    async with api.LiveKitAPI(
        url=os.environ["LIVEKIT_URL"],
        api_key=os.environ["LIVEKIT_API_KEY"],
        api_secret=os.environ["LIVEKIT_API_SECRET"],
    ) as lk:
        # create room (idempotent)
        try:
            await lk.room.create_room(api.CreateRoomRequest(name="smoke"))
        except api.RpcError as e:
            if getattr(e, "code", None) != api.ErrorCode.ROOM_ALREADY_EXISTS:
                raise

        resp = await lk.room.list_rooms(api.ListRoomsRequest())
        print("rooms:", [r.name for r in resp.rooms])

if __name__ == "__main__":
    asyncio.run(main())
