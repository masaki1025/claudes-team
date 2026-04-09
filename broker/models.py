"""Data models for the claude-peers broker."""

from pydantic import BaseModel
from typing import Optional


# --- Request models ---

class SessionRegister(BaseModel):
    role: str
    namespace: str
    work_dir: str
    git_repo: Optional[str] = None
    channel_url: str


class SummaryUpdate(BaseModel):
    summary: str


class RoleUpdate(BaseModel):
    role: str


class MessageSend(BaseModel):
    from_id: str
    to_id: str
    content: str


class BroadcastSend(BaseModel):
    from_id: str
    content: str


class ModeUpdate(BaseModel):
    mode: str


class LockRequest(BaseModel):
    session_id: str
    file_path: str
