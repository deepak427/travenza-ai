# Travenza AI — Backend

Live bidirectional voice AI travel guide powered by Gemini Live API.

## Setup

```bash
cd travenza-ai
python -m venv .venv
.venv\Scripts\activate       # Windows
# source .venv/bin/activate  # Mac/Linux

pip install -r requirements.txt

cp .env.example .env
# Edit .env with your PROJECT_ID
```

## Run

```bash
python -m server.main
```

Server starts at `http://localhost:8080`

## API

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/status` | Health check |
| GET | `/api/guides` | List available travel guide personas |
| POST | `/api/auth` | Get a session token |
| WS | `/ws?token=<token>` | Live audio session |

### Auth request body
```json
{ "guide_id": "explorer" }
```

### Available guides
- `explorer` — Adventure & off-the-beaten-path (Alex)
- `cultural` — Culture, history & local experiences (Sofia)
- `luxury` — Luxury & premium travel concierge (James)
- `budget` — Budget travel & backpacking (Maya)

### WebSocket flow
1. POST `/api/auth` → get `session_token`
2. Connect `ws://localhost:8080/ws?token=<session_token>`
3. Send raw PCM audio bytes (16kHz, 16-bit, mono)
4. Receive audio bytes (AI voice) + JSON events (transcriptions, turn signals)

### JSON events from server
```json
{ "serverContent": { "inputTranscription": { "text": "...", "finished": true } } }
{ "serverContent": { "outputTranscription": { "text": "...", "finished": true } } }
{ "serverContent": { "turnComplete": true } }
{ "serverContent": { "interrupted": true } }
```
