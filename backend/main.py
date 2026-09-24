# Compatibility entry point for platforms that auto-start `uvicorn main:app`.
from app import app

__all__ = ["app"]
