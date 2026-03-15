import hashlib
from fastapi import Request

def generate_fingerprint(request: Request):
    client_host = request.client.host if request.client else "unknown"
    raw_id = "|".join([
        client_host,
        request.headers.get("User-Agent", ""),
        request.headers.get("Accept-Language", ""),
        request.headers.get("Accept", ""),
    ])
    return hashlib.sha256(raw_id.encode()).hexdigest()
