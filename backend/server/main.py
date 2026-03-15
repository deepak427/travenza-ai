import asyncio
import json
import logging
import os
import time
import uuid
from typing import Dict, Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

from server.config_utils import get_project_id
from server.fingerprint import generate_fingerprint
from server.gemini_live import GeminiLive
from server.guides import DEFAULT_GUIDE, get_guide

# Rate limiting
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address

load_dotenv(override=True)

# Ensure google.auth picks up the project ID
if os.getenv("PROJECT_ID"):
    os.environ.setdefault("GOOGLE_CLOUD_PROJECT", os.getenv("PROJECT_ID"))

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ID = get_project_id()
LOCATION = os.getenv("LOCATION", "us-central1")
MODEL = os.getenv("MODEL", "gemini-live-2.5-flash-native-audio")
SESSION_TIME_LIMIT = int(os.getenv("SESSION_TIME_LIMIT", "300"))
REDIS_URL = os.getenv("REDIS_URL")
GLOBAL_RATE_LIMIT = os.getenv("GLOBAL_RATE_LIMIT", "1000 per hour")
PER_USER_RATE_LIMIT = os.getenv("PER_USER_RATE_LIMIT", "10 per minute")
DEV_MODE = os.getenv("DEV_MODE", "true") == "true"

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(title="Travenza AI", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Rate Limiter ──────────────────────────────────────────────────────────────
def get_fingerprint_key(request: Request):
    return generate_fingerprint(request)

def get_global_key(request: Request):
    return "global"

if DEV_MODE:
    logger.info("DEV_MODE: rate limiting disabled")
    limiter = Limiter(key_func=get_global_key)
elif REDIS_URL:
    limiter = Limiter(key_func=get_fingerprint_key, storage_uri=REDIS_URL)
else:
    logger.warning("No REDIS_URL: using in-memory rate limiting")
    limiter = Limiter(key_func=get_fingerprint_key)

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# ── Session tokens ───────────────────────────────────────────────────────────
valid_tokens: Dict[str, dict] = {}
TOKEN_EXPIRY = 30

def cleanup_tokens():
    now = time.time()
    expired = [t for t, v in valid_tokens.items() if now - v["ts"] > TOKEN_EXPIRY]
    for t in expired:
        del valid_tokens[t]

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/")
async def root():
    return FileResponse("static/index.html")

@app.get("/api/status")
async def status():
    return {
        "status": "ok",
        "dev_mode": DEV_MODE,
        "model": MODEL,
        "session_time_limit": SESSION_TIME_LIMIT,
    }

@app.get("/api/guides")
async def list_guides():
    from server.guides import GUIDES
    return {
        guide_id: {
            "name": g["name"],
            "description": g["description"],
            "voice": g["voice"],
        }
        for guide_id, g in GUIDES.items()
    }

@app.post("/api/auth")
@limiter.limit(GLOBAL_RATE_LIMIT, key_func=get_global_key)
@limiter.limit(PER_USER_RATE_LIMIT, key_func=get_fingerprint_key)
async def authenticate(request: Request):
    try:
        data = await request.json()
        guide_id = data.get("guide_id", DEFAULT_GUIDE)
        guide = get_guide(guide_id)
        token = str(uuid.uuid4())
        cleanup_tokens()
        valid_tokens[token] = {"ts": time.time(), "guide_id": guide_id}
        return {
            "session_token": token,
            "session_time_limit": SESSION_TIME_LIMIT,
            "guide": { "id": guide_id, "name": guide["name"], "description": guide["description"] },
        }
    except Exception as e:
        logger.error(f"Auth error: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: Optional[str] = None):
    await websocket.accept()
    if not token or token not in valid_tokens:
        await websocket.close(code=4003, reason="Unauthorized")
        return

    token_data = valid_tokens.pop(token)
    guide_id = token_data.get("guide_id", DEFAULT_GUIDE)
    
    audio_input_queue: asyncio.Queue = asyncio.Queue()
    text_input_queue: asyncio.Queue = asyncio.Queue()
    setup_event: asyncio.Event = asyncio.Event()
    setup_config: Optional[dict] = None

    ws_lock = asyncio.Lock()

    async def audio_output_callback(data: bytes):
        try:
            async with ws_lock:
                await websocket.send_bytes(data)
            if len(data) > 0:
                logger.debug(f"Sent {len(data)} audio bytes to client")
        except Exception as e:
            logger.error(f"Error sending audio: {e}")

    gemini = GeminiLive(
        project_id=PROJECT_ID,
        location=LOCATION,
        model=MODEL,
        input_sample_rate=16000,
    )

    async def receive_from_client():
        nonlocal setup_config
        try:
            while True:
                message = await websocket.receive()
                if "text" in message and message["text"]:
                    data = json.loads(message["text"])
                    if "setup" in data:
                        setup_config = data["setup"]
                        setup_event.set()
                    else:
                        await text_input_queue.put(message["text"])
                elif "bytes" in message and message["bytes"]:
                    await audio_input_queue.put(message["bytes"])
                elif "type" in message and message["type"] == "websocket.disconnect":
                    break
        except (WebSocketDisconnect, asyncio.CancelledError):
            pass
        finally:
            setup_event.set()

    receive_task = asyncio.create_task(receive_from_client())

    async def run_session():
        try:
            await asyncio.wait_for(setup_event.wait(), timeout=5.0)
        except asyncio.TimeoutError:
            logger.warning("No setup message received, using defaults")

        async for event in gemini.start_session(
            audio_input_queue=audio_input_queue,
            text_input_queue=text_input_queue,
            audio_output_callback=audio_output_callback,
            setup_config=setup_config
        ):
            if event:
                async with ws_lock:
                    await websocket.send_json(event)

    try:
        await asyncio.wait_for(run_session(), timeout=SESSION_TIME_LIMIT)
    except Exception as e:
        logger.info(f"Session finished: {e}")
    finally:
        receive_task.cancel()
        try:
            await websocket.close()
        except:
            pass

# Serve remaining static files
app.mount("/static", StaticFiles(directory="static"), name="static")

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 8080))
    uvicorn.run("server.main:app", host="0.0.0.0", port=port, reload=DEV_MODE)
