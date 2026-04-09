"""SQLite database operations for the claude-peers broker."""

import aiosqlite
from datetime import datetime, timezone
from typing import Optional

DB_PATH = "claude_peers.db"


async def init_db(db_path: str = DB_PATH) -> aiosqlite.Connection:
    """Initialize the database and create tables."""
    db = await aiosqlite.connect(db_path)
    db.row_factory = aiosqlite.Row

    await db.executescript("""
        CREATE TABLE IF NOT EXISTS peers (
            session_id     TEXT PRIMARY KEY,
            namespace      TEXT NOT NULL,
            role           TEXT,
            work_dir       TEXT,
            git_repo       TEXT,
            current_task   TEXT,
            mode           TEXT DEFAULT 'HYBRID',
            channel_url    TEXT NOT NULL,
            last_heartbeat DATETIME DEFAULT CURRENT_TIMESTAMP,
            created_at     DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_peers_namespace ON peers(namespace);

        CREATE TABLE IF NOT EXISTS messages (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            from_id    TEXT NOT NULL,
            to_id      TEXT,
            namespace  TEXT NOT NULL,
            content    TEXT NOT NULL,
            read_flag  INTEGER DEFAULT 0,
            timestamp  DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_messages_to_id ON messages(to_id, read_flag);
        CREATE INDEX IF NOT EXISTS idx_messages_namespace ON messages(namespace);

        CREATE TABLE IF NOT EXISTS file_locks (
            file_path   TEXT PRIMARY KEY,
            session_id  TEXT NOT NULL,
            namespace   TEXT NOT NULL,
            acquired_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            expires_at  DATETIME NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_locks_namespace ON file_locks(namespace);
        CREATE INDEX IF NOT EXISTS idx_locks_session ON file_locks(session_id);

        -- TODO: Phase 6 で使用予定（タスクキュー機能）
        CREATE TABLE IF NOT EXISTS tasks (
            task_id        TEXT PRIMARY KEY,
            namespace      TEXT NOT NULL,
            assignee_id    TEXT,
            role           TEXT,
            status         TEXT DEFAULT 'pending',
            description    TEXT,
            files          TEXT,
            parent_task_id TEXT,
            created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at     DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_tasks_namespace ON tasks(namespace);
        CREATE INDEX IF NOT EXISTS idx_tasks_assignee ON tasks(assignee_id);
    """)
    await db.commit()
    return db


def now_iso() -> str:
    """Return current UTC time as ISO string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- Session operations ---

async def generate_session_id(db: aiosqlite.Connection, role: str, namespace: str) -> str:
    """Generate a session_id based on role and namespace."""
    if role == "dispatcher":
        return "dispatcher-1"
    # Count existing workers in this namespace
    cursor = await db.execute(
        "SELECT COUNT(*) FROM peers WHERE namespace = ? AND session_id LIKE 'worker-%'",
        (namespace,),
    )
    row = await cursor.fetchone()
    count = row[0] if row else 0
    return f"worker-{count + 1}"


async def register_session(
    db: aiosqlite.Connection,
    session_id: str,
    namespace: str,
    role: str,
    work_dir: str,
    git_repo: Optional[str],
    channel_url: str,
) -> None:
    """Register a new session. Caller is responsible for commit/transaction."""
    now = now_iso()
    await db.execute(
        """INSERT OR REPLACE INTO peers
           (session_id, namespace, role, work_dir, git_repo, channel_url, last_heartbeat, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (session_id, namespace, role, work_dir, git_repo, channel_url, now, now),
    )


async def delete_session(db: aiosqlite.Connection, session_id: str) -> bool:
    """Delete a session. Returns True if found."""
    cursor = await db.execute("DELETE FROM peers WHERE session_id = ?", (session_id,))
    await db.commit()
    return cursor.rowcount > 0


async def get_session(db: aiosqlite.Connection, session_id: str) -> Optional[dict]:
    """Get a single session by ID."""
    cursor = await db.execute("SELECT * FROM peers WHERE session_id = ?", (session_id,))
    row = await cursor.fetchone()
    if row is None:
        return None
    return dict(row)


async def get_sessions(db: aiosqlite.Connection, namespace: str) -> list[dict]:
    """Get all sessions in a namespace."""
    cursor = await db.execute(
        "SELECT * FROM peers WHERE namespace = ? ORDER BY created_at",
        (namespace,),
    )
    rows = await cursor.fetchall()
    return [dict(r) for r in rows]


async def update_heartbeat(db: aiosqlite.Connection, session_id: str) -> bool:
    """Update last_heartbeat for a session. Returns True if found."""
    now = now_iso()
    cursor = await db.execute(
        "UPDATE peers SET last_heartbeat = ? WHERE session_id = ?",
        (now, session_id),
    )
    await db.commit()
    return cursor.rowcount > 0


async def update_role(db: aiosqlite.Connection, session_id: str, role: str) -> bool:
    """Update role for a session. Returns True if found."""
    cursor = await db.execute(
        "UPDATE peers SET role = ? WHERE session_id = ?",
        (role, session_id),
    )
    await db.commit()
    return cursor.rowcount > 0


async def update_mode(db: aiosqlite.Connection, session_id: str, mode: str) -> bool:
    """Update autonomy mode for a session. Returns True if found."""
    cursor = await db.execute(
        "UPDATE peers SET mode = ? WHERE session_id = ?",
        (mode, session_id),
    )
    await db.commit()
    return cursor.rowcount > 0


async def update_summary(db: aiosqlite.Connection, session_id: str, summary: str) -> bool:
    """Update current_task for a session. Returns True if found."""
    cursor = await db.execute(
        "UPDATE peers SET current_task = ? WHERE session_id = ?",
        (summary, session_id),
    )
    await db.commit()
    return cursor.rowcount > 0


async def get_stale_sessions(db: aiosqlite.Connection, timeout_seconds: int = 60) -> list[dict]:
    """Get sessions that haven't sent a heartbeat within timeout."""
    cursor = await db.execute(
        """SELECT * FROM peers
           WHERE datetime(last_heartbeat, '+' || ? || ' seconds') < datetime('now')""",
        (timeout_seconds,),
    )
    rows = await cursor.fetchall()
    return [dict(r) for r in rows]


async def cleanup_stale_sessions(db: aiosqlite.Connection, timeout_seconds: int = 60) -> list[str]:
    """Remove stale sessions and their locks atomically. Returns list of removed session_ids."""
    stale = await get_stale_sessions(db, timeout_seconds)
    if not stale:
        return []
    removed = []
    await db.execute("BEGIN IMMEDIATE")
    try:
        for s in stale:
            sid = s["session_id"]
            await db.execute("DELETE FROM peers WHERE session_id = ?", (sid,))
            await db.execute("DELETE FROM file_locks WHERE session_id = ?", (sid,))
            removed.append(sid)
        await db.commit()
    except Exception:
        await db.execute("ROLLBACK")
        raise
    return removed


# --- Message operations ---

async def store_message(
    db: aiosqlite.Connection,
    from_id: str,
    to_id: Optional[str],
    namespace: str,
    content: str,
) -> int:
    """Store a message and return its ID."""
    now = now_iso()
    cursor = await db.execute(
        """INSERT INTO messages (from_id, to_id, namespace, content, timestamp)
           VALUES (?, ?, ?, ?, ?)""",
        (from_id, to_id, namespace, content, now),
    )
    await db.commit()
    return cursor.lastrowid


async def get_unread_messages(db: aiosqlite.Connection, session_id: str) -> list[dict]:
    """Get unread messages for a session and mark them as read."""
    cursor = await db.execute(
        """SELECT id, from_id, content, timestamp FROM messages
           WHERE to_id = ? AND read_flag = 0
           ORDER BY timestamp""",
        (session_id,),
    )
    rows = await cursor.fetchall()
    messages = [dict(r) for r in rows]
    if messages:
        ids = [m["id"] for m in messages]
        placeholders = ",".join("?" * len(ids))
        await db.execute(
            f"UPDATE messages SET read_flag = 1 WHERE id IN ({placeholders})", ids
        )
        await db.commit()
    return messages


# --- File lock operations ---

async def acquire_lock(
    db: aiosqlite.Connection,
    file_path: str,
    session_id: str,
    namespace: str,
    duration_minutes: int = 30,
) -> dict:
    """Try to acquire a file lock. Uses BEGIN IMMEDIATE for atomicity."""
    from datetime import timedelta

    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT * FROM file_locks WHERE file_path = ?", (file_path,)
        )
        existing = await cursor.fetchone()

        if existing:
            existing = dict(existing)
            expires = existing["expires_at"]
            is_expired = (
                expires
                and datetime.fromisoformat(expires.replace("Z", "+00:00"))
                < datetime.now(timezone.utc)
            )

            if is_expired:
                await db.execute("DELETE FROM file_locks WHERE file_path = ?", (file_path,))
            elif existing["session_id"] != session_id:
                await db.execute("ROLLBACK")
                return {
                    "status": "conflict",
                    "locked_by": existing["session_id"],
                    "acquired_at": existing["acquired_at"],
                }

        now = datetime.now(timezone.utc)
        expires_at = (now + timedelta(minutes=duration_minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
        now_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")

        await db.execute(
            """INSERT OR REPLACE INTO file_locks (file_path, session_id, namespace, acquired_at, expires_at)
               VALUES (?, ?, ?, ?, ?)""",
            (file_path, session_id, namespace, now_str, expires_at),
        )
        await db.commit()
        return {"status": "ok", "expires_at": expires_at}
    except Exception:
        await db.execute("ROLLBACK")
        raise


async def release_lock(db: aiosqlite.Connection, session_id: str, file_path: str) -> bool:
    """Release a file lock. Returns True if found."""
    cursor = await db.execute(
        "DELETE FROM file_locks WHERE session_id = ? AND file_path = ?",
        (session_id, file_path),
    )
    await db.commit()
    return cursor.rowcount > 0


async def get_locks(db: aiosqlite.Connection, namespace: str) -> list[dict]:
    """Get all locks in a namespace."""
    cursor = await db.execute(
        """SELECT fl.file_path, fl.session_id, COALESCE(p.role, 'unknown') as role, fl.acquired_at, fl.expires_at
           FROM file_locks fl
           LEFT JOIN peers p ON fl.session_id = p.session_id
           WHERE fl.namespace = ?""",
        (namespace,),
    )
    rows = await cursor.fetchall()
    return [dict(r) for r in rows]


async def release_session_locks(db: aiosqlite.Connection, session_id: str) -> int:
    """Release all locks held by a session. Returns count released."""
    cursor = await db.execute(
        "DELETE FROM file_locks WHERE session_id = ?", (session_id,)
    )
    await db.commit()
    return cursor.rowcount
