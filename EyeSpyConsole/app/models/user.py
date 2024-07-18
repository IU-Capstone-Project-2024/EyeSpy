from pydantic import BaseModel

from .vector import Vector


class User(BaseModel):
    name: str
    device_id: str
    is_cheating: bool
    gaze: Vector
