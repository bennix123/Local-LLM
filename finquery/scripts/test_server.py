import os
import sys

# Ensure proper sys.path so modules can find each other
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, ROOT)

import uvicorn
from scripts.test_server.server import app, PORT
from src.services import txn_store as ts

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT)
