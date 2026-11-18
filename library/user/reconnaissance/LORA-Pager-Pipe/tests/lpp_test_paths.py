"""Locate source in the development repository or a standalone payload folder."""
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
PAYLOAD_ROOT = PROJECT_ROOT / "payload"
if not (PAYLOAD_ROOT / "lpp.py").is_file():
    PAYLOAD_ROOT = PROJECT_ROOT
if not (PAYLOAD_ROOT / "lpp.py").is_file() or not (PAYLOAD_ROOT / "lib" / "lpp").is_dir():
    raise RuntimeError("Tests must be beside the complete payload source")
