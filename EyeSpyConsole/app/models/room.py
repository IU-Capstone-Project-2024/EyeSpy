from pydantic import BaseModel

from .user import User


class Room(BaseModel):
    code: str
    users: dict[str, User]
