"""
auth.py — Penny authentication layer
=====================================
- User credentials stored in  data/users.db  (SQLite, bcrypt-hashed passwords)
- Per-user transaction databases at  data/user_dbs/<username>.db
- JWT (HS256) tokens; default 7-day expiry
- FastAPI Depends helper: get_current_user(token) → username str
"""
import sys, os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "backend")))

import sqlite3, secrets
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, HTTPException, status, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel

try:
    from jose import JWTError, jwt
except ImportError:
    raise RuntimeError("python-jose not installed. Run: pip install 'python-jose[cryptography]'")

try:
    from passlib.context import CryptContext
except ImportError:
    raise RuntimeError("passlib not installed. Run: pip install 'passlib[bcrypt]'")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
_BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "data"))
USERS_DB  = os.path.join(_BASE, "users.db")
USER_DBS  = os.path.join(_BASE, "user_dbs")
os.makedirs(USER_DBS, exist_ok=True)

# JWT secret — read from env, else generate a fresh random key per run (dev mode)
JWT_SECRET    = os.environ.get("JWT_SECRET") or secrets.token_hex(32)
JWT_ALGORITHM = "HS256"
JWT_EXPIRY_DAYS = int(os.environ.get("JWT_EXPIRY_DAYS", "7"))

if not os.environ.get("JWT_SECRET"):
    print("[auth] WARNING: JWT_SECRET not set — using a random key (tokens reset on restart). "
          "Set JWT_SECRET env var for persistence.", flush=True)

# ---------------------------------------------------------------------------
# Password hashing
# ---------------------------------------------------------------------------
import bcrypt

def _hash(pw: str) -> str:
    return bcrypt.hashpw(pw.encode(), bcrypt.gensalt()).decode()

def _verify(plain: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(plain.encode(), hashed.encode())
    except Exception:
        return False

# ---------------------------------------------------------------------------
# Users DB
# ---------------------------------------------------------------------------
def _users_conn():
    conn = sqlite3.connect(USERS_DB, check_same_thread=False)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS users (
            username    TEXT PRIMARY KEY,
            pw_hash     TEXT NOT NULL,
            created_at  TEXT NOT NULL
        )
    """)
    conn.commit()
    return conn

def _user_exists(username: str) -> bool:
    with _users_conn() as c:
        row = c.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone()
    return row is not None

def _create_user(username: str, pw_hash: str):
    with _users_conn() as c:
        c.execute(
            "INSERT INTO users (username, pw_hash, created_at) VALUES (?,?,?)",
            (username, pw_hash, datetime.now(timezone.utc).isoformat())
        )
        c.commit()

def _get_pw_hash(username: str) -> Optional[str]:
    with _users_conn() as c:
        row = c.execute("SELECT pw_hash FROM users WHERE username=?", (username,)).fetchone()
    return row[0] if row else None

# ---------------------------------------------------------------------------
# JWT helpers
# ---------------------------------------------------------------------------
def _make_token(username: str) -> str:
    exp = datetime.now(timezone.utc) + timedelta(days=JWT_EXPIRY_DAYS)
    return jwt.encode({"sub": username, "exp": exp}, JWT_SECRET, algorithm=JWT_ALGORITHM)

def _decode_token(token: str) -> Optional[str]:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return payload.get("sub")
    except JWTError:
        return None

# ---------------------------------------------------------------------------
# Per-user DB path
# ---------------------------------------------------------------------------
def get_user_db_path(username: str) -> str:
    """Return the absolute path to this user's transaction SQLite file."""
    safe = "".join(c for c in username if c.isalnum() or c in "_-").lower()
    return os.path.join(USER_DBS, f"{safe}.db")

# ---------------------------------------------------------------------------
# FastAPI security dependency
# ---------------------------------------------------------------------------
_bearer = HTTPBearer(auto_error=False)

def get_current_user(
    creds: Optional[HTTPAuthorizationCredentials] = Depends(_bearer)
) -> str:
    """FastAPI dependency: validates JWT and returns the username.
    Falls back to 'local' for local dev/offline mode instead of raising 401."""
    if not creds:
        return "local"
    username = _decode_token(creds.credentials)
    if not username:
        return "local"
    return username

def get_optional_user(
    creds: Optional[HTTPAuthorizationCredentials] = Depends(_bearer)
) -> Optional[str]:
    """Like get_current_user but returns None instead of raising (for / route)."""
    if not creds:
        return None
    return _decode_token(creds.credentials)

# ---------------------------------------------------------------------------
# Auth router  (/auth/signup  /auth/login  /auth/me)
# ---------------------------------------------------------------------------
router = APIRouter(prefix="/auth", tags=["auth"])

class _Creds(BaseModel):
    username: str
    password: str

@router.post("/signup")
def signup(body: _Creds):
    uname = body.username.strip().lower()
    if not uname or len(uname) < 3:
        raise HTTPException(400, "Username must be at least 3 characters.")
    if len(body.password) < 6:
        raise HTTPException(400, "Password must be at least 6 characters.")
    if _user_exists(uname):
        raise HTTPException(409, "Username already taken.")
    _create_user(uname, _hash(body.password))
    token = _make_token(uname)
    print(f"[auth] new user registered: {uname}", flush=True)
    return {"token": token, "username": uname, "expires_days": JWT_EXPIRY_DAYS}

@router.post("/login")
def login(body: _Creds):
    uname = body.username.strip().lower()
    pw_hash = _get_pw_hash(uname)
    if not pw_hash or not _verify(body.password, pw_hash):
        raise HTTPException(401, "Invalid username or password.")
    token = _make_token(uname)
    print(f"[auth] login: {uname}", flush=True)
    return {"token": token, "username": uname, "expires_days": JWT_EXPIRY_DAYS}

@router.get("/me")
def me(user: str = Depends(get_current_user)):
    return {"username": user}
