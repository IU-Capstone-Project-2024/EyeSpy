import json
import secrets
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from .models.room import Room
from .models.user import User

app = FastAPI()

rooms = {}
rooms_sockets = {}

templates = Jinja2Templates(directory="app/templates")


@app.get('/', response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse(
        request=request, name="create.html"
    )


@app.get('/rooms/{code}', response_class=HTMLResponse)
def room(code: str, request: Request):
    return templates.TemplateResponse(
        request=request, name="room.html", context={"code": code}
    )


@app.post('/api/rooms')
def create_room() -> Room:
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456789"
    code = "".join(secrets.choice(chars) for _ in range(7))

    room = Room(
        code=code,
        users={}
    )
    rooms[code] = room
    rooms_sockets[code] = []

    return room


@app.websocket("/ws/rooms/{code}/client")
async def websocket_endpoint(code: str, websocket: WebSocket):
    await websocket.accept()
    device_id = None

    while True:
        try:
            data = json.loads(
                (await websocket.receive_bytes()).decode('utf8')
            )
            user = User(**data)
            rooms[code].users[user.device_id] = user
            device_id = user.device_id

            for socket in rooms_sockets[code]:
                await socket.send_json(
                    rooms[code].dict()
                )
        except WebSocketDisconnect:
            del rooms[code].users[device_id]
            for socket in rooms_sockets[code]:
                await socket.send_json(
                    rooms[code].dict()
                )
            return


@app.websocket("/ws/rooms/{code}/console")
async def websocket_endpoint(code: str, websocket: WebSocket):
    await websocket.accept()
    rooms_sockets[code].append(websocket)
    await websocket.send_json(
        rooms[code].dict()
    )

    while True:
        try:
            await websocket.receive_json()
        except WebSocketDisconnect:
            rooms_sockets[code].remove(websocket)
