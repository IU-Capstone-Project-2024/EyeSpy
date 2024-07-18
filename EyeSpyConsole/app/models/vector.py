from pydantic import BaseModel


class Vector(BaseModel):
    x: float
    y: float
