"""claude-peers broker daemon - FastAPI application."""

import argparse
import asyncio
import logging
import os
import signal
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, Query

from database import init_db, DB_PATH
import database as db
from models import (
    SessionRegister,
    SummaryUpdate,
    RoleUpdate,
    ModeUpdate,
    MessageSend,
    BroadcastSend,
    LockRequest,
)

VERSION = "1.0.0"
HEARTBEAT_TIMEOUT = 60  # seconds

logger = logging.getLogger("broker")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)

# Global database connection
_db = None
_cleanup_task = None


async def get_db():
    return _db


async def deliver_to_channel(channel_url: str, payload: dict) -> bool:
    """Deliver a message to a channel server's /push endpoint."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(channel_url, json=payload)
            return resp.status_code == 200
    except Exception as e:
        logger.warning(f"Failed to deliver to {channel_url}: {e}")
        return False


async def cleanup_loop():
    """Periodically clean up stale sessions."""
    while True:
        await asyncio.sleep(30)
        try:
            removed = await db.cleanup_stale_sessions(_db, HEARTBEAT_TIMEOUT)
            if removed:
                logger.info(f"Cleaned up stale sessions: {removed}")
        except Exception as e:
            logger.error(f"Cleanup error: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _db, _cleanup_task
    _db = await init_db(DB_PATH)
    _cleanup_task = asyncio.create_task(cleanup_loop())
    logger.info(f"Broker started (version {VERSION})")
    yield
    _cleanup_task.cancel()
    if _db:
        await _db.close()
    logger.info("Broker stopped")


app = FastAPI(title="claude-peers broker", version=VERSION, lifespan=lifespan)


# --- Error helper ---

def error_response(code: str, message: str, status_code: int = 400):
    raise HTTPException(
        status_code=status_code,
        detail={"status": "error", "code": code, "message": message},
    )


# ===================
# System management
# ===================

@app.get("/health")
async def health():
    conn = await get_db()
    cursor = await conn.execute("SELECT COUNT(*) FROM peers")
    row = await cursor.fetchone()
    return {"status": "ok", "version": VERSION, "sessions": row[0]}


@app.post("/shutdown")
async def shutdown():
    conn = await get_db()
    cursor = await conn.execute("SELECT session_id, channel_url FROM peers")
    rows = await cursor.fetchall()
    notified = 0
    for row in rows:
        row = dict(row)
        success = await deliver_to_channel(
            row["channel_url"],
            {"type": "shutdown", "message": "ブローカーが停止します"},
        )
        if success:
            notified += 1

    # Schedule shutdown after response
    async def _shutdown():
        await asyncio.sleep(0.5)
        os.kill(os.getpid(), signal.SIGTERM)

    asyncio.create_task(_shutdown())
    return {"status": "ok", "notified": notified}


# ===================
# Session management
# ===================

@app.post("/sessions")
async def register_session(req: SessionRegister):
    conn = await get_db()

    # Validate channel_url format
    if not req.channel_url.startswith("http://127.0.0.1:") and not req.channel_url.startswith("http://localhost:"):
        error_response("INVALID_REQUEST", "channel_url は http://127.0.0.1 または http://localhost で始まる必要があります")

    # Atomic dispatcher check + registration
    await conn.execute("BEGIN IMMEDIATE")
    try:
        session_id = await db.generate_session_id(conn, req.role, req.namespace)

        if req.role == "dispatcher":
            existing = await db.get_session(conn, "dispatcher-1")
            if existing:
                if existing["namespace"] != req.namespace:
                    await conn.execute("ROLLBACK")
                    error_response("NAMESPACE_MISMATCH", f"別のnamespace ({existing['namespace']}) の Dispatcher が既に存在します")
                await conn.execute("DELETE FROM peers WHERE session_id = ?", ("dispatcher-1",))

        await db.register_session(
            conn,
            session_id=session_id,
            namespace=req.namespace,
            role=req.role,
            work_dir=req.work_dir,
            git_repo=req.git_repo,
            channel_url=req.channel_url,
        )
        await conn.commit()
    except Exception:
        await conn.execute("ROLLBACK")
        raise

    logger.info(f"Session registered: {session_id} (role={req.role}, ns={req.namespace})")
    return {"status": "ok", "session_id": session_id}


@app.delete("/sessions/{session_id}")
async def delete_session(session_id: str):
    conn = await get_db()
    # Delete session and release its locks atomically
    await conn.execute("BEGIN IMMEDIATE")
    try:
        cursor = await conn.execute("DELETE FROM peers WHERE session_id = ?", (session_id,))
        if cursor.rowcount == 0:
            await conn.execute("ROLLBACK")
            error_response("SESSION_NOT_FOUND", "セッションが見つかりません", 404)
        await conn.execute("DELETE FROM file_locks WHERE session_id = ?", (session_id,))
        await conn.commit()
    except Exception:
        await conn.execute("ROLLBACK")
        raise
    logger.info(f"Session deleted: {session_id}")
    return {"status": "ok"}


@app.put("/sessions/{session_id}/heartbeat")
async def heartbeat(session_id: str):
    conn = await get_db()
    found = await db.update_heartbeat(conn, session_id)
    if not found:
        error_response("SESSION_NOT_FOUND", "セッションが見つかりません", 404)
    return {"status": "ok"}


@app.get("/sessions")
async def list_sessions(namespace: str = Query(...)):
    conn = await get_db()
    sessions = await db.get_sessions(conn, namespace)
    return {
        "sessions": [
            {
                "session_id": s["session_id"],
                "role": s["role"],
                "mode": s["mode"],
                "work_dir": s["work_dir"],
                "current_task": s["current_task"],
                "last_heartbeat": s["last_heartbeat"],
            }
            for s in sessions
        ]
    }


@app.put("/sessions/{session_id}/summary")
async def update_summary(session_id: str, req: SummaryUpdate):
    conn = await get_db()
    found = await db.update_summary(conn, session_id, req.summary)
    if not found:
        error_response("SESSION_NOT_FOUND", "セッションが見つかりません", 404)
    return {"status": "ok"}


@app.put("/sessions/{session_id}/role")
async def update_role(session_id: str, req: RoleUpdate):
    conn = await get_db()
    found = await db.update_role(conn, session_id, req.role)
    if not found:
        error_response("SESSION_NOT_FOUND", "セッションが見つかりません", 404)
    return {"status": "ok"}


@app.put("/sessions/{session_id}/mode")
async def update_mode(session_id: str, req: ModeUpdate):
    conn = await get_db()
    if req.mode not in ("MANUAL", "HYBRID", "FULL_AUTO"):
        error_response("INVALID_REQUEST", "モードは MANUAL / HYBRID / FULL_AUTO のいずれかです")
    found = await db.update_mode(conn, session_id, req.mode)
    if not found:
        error_response("SESSION_NOT_FOUND", "セッションが見つかりません", 404)
    return {"status": "ok"}


# ===================
# Messaging
# ===================

@app.post("/messages")
async def send_message(req: MessageSend):
    conn = await get_db()

    # Verify sender exists
    sender = await db.get_session(conn, req.from_id)
    if not sender:
        error_response("SESSION_NOT_FOUND", f"送信元セッション {req.from_id} が見つかりません", 404)

    # Verify recipient exists
    recipient = await db.get_session(conn, req.to_id)
    if not recipient:
        error_response("SESSION_NOT_FOUND", f"宛先セッション {req.to_id} が見つかりません", 404)

    # Check namespace match
    if sender["namespace"] != recipient["namespace"]:
        error_response("NAMESPACE_MISMATCH", "送信元と宛先のnamespaceが一致しません")

    # Store message
    msg_id = await db.store_message(
        conn, req.from_id, req.to_id, sender["namespace"], req.content
    )

    # Deliver to channel server
    payload = {
        "from_id": req.from_id,
        "from_role": sender["role"] or "unknown",
        "content": req.content,
        "timestamp": db.now_iso(),
    }
    delivered = await deliver_to_channel(recipient["channel_url"], payload)

    logger.info(f"Message {msg_id}: {req.from_id} -> {req.to_id} (delivered={delivered})")
    result = {"status": "ok", "message_id": f"msg-{msg_id:03d}"}
    if not delivered:
        result["warning"] = f"メッセージは保存されましたが、{req.to_id} への配信に失敗しました"
    return result


@app.post("/messages/broadcast")
async def broadcast_message(req: BroadcastSend):
    conn = await get_db()

    sender = await db.get_session(conn, req.from_id)
    if not sender:
        error_response("SESSION_NOT_FOUND", f"送信元セッション {req.from_id} が見つかりません", 404)

    namespace = sender["namespace"]
    sessions = await db.get_sessions(conn, namespace)

    delivered_to = []
    failed_to = []
    for s in sessions:
        if s["session_id"] == req.from_id:
            continue  # Don't send to self

        # Store individual message
        await db.store_message(conn, req.from_id, s["session_id"], namespace, req.content)

        # Deliver
        payload = {
            "from_id": req.from_id,
            "from_role": sender["role"] or "unknown",
            "content": req.content,
            "timestamp": db.now_iso(),
        }
        success = await deliver_to_channel(s["channel_url"], payload)
        if success:
            delivered_to.append(s["session_id"])
        else:
            failed_to.append(s["session_id"])

    logger.info(f"Broadcast from {req.from_id}: delivered={delivered_to}, failed={failed_to}")
    result: dict = {"status": "ok", "delivered_to": delivered_to}
    if failed_to:
        result["warning"] = f"以下のセッションへの配信に失敗しました: {', '.join(failed_to)}"
    return result


@app.get("/messages/{session_id}")
async def get_messages(session_id: str):
    conn = await get_db()
    session = await db.get_session(conn, session_id)
    if not session:
        error_response("SESSION_NOT_FOUND", "セッションが見つかりません", 404)

    messages = await db.get_unread_messages(conn, session_id)
    return {
        "messages": [
            {
                "message_id": f"msg-{m['id']:03d}",
                "from_id": m["from_id"],
                "content": m["content"],
                "timestamp": m["timestamp"],
            }
            for m in messages
        ]
    }


# ===================
# File locks
# ===================

@app.post("/locks")
async def acquire_lock(req: LockRequest):
    conn = await get_db()

    session = await db.get_session(conn, req.session_id)
    if not session:
        error_response("SESSION_NOT_FOUND", "セッションが見つかりません", 404)

    result = await db.acquire_lock(
        conn, req.file_path, req.session_id, session["namespace"]
    )

    if result["status"] == "conflict":
        # Notify the requesting session about the conflict
        return result

    return result


@app.delete("/locks/{session_id}/{file_path:path}")
async def release_lock(session_id: str, file_path: str):
    conn = await get_db()
    found = await db.release_lock(conn, session_id, file_path)
    if not found:
        return {"status": "ok", "message": "ロックが見つかりませんでした"}
    logger.info(f"Lock released: {file_path} by {session_id}")
    return {"status": "ok"}


@app.get("/locks")
async def list_locks(namespace: str = Query(...)):
    conn = await get_db()
    locks = await db.get_locks(conn, namespace)
    return {"locks": locks}


# ===================
# Entry point
# ===================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="claude-peers broker daemon")
    parser.add_argument("--port", type=int, default=7799, help="Port to listen on")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="Host to bind to")
    args = parser.parse_args()

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
