# Compatibility entry point for platforms that auto-start `uvicorn main:app`.
from app import app
from gmail_oauth import router as gmail_oauth_router
from gmail_reconstruction import router as gmail_reconstruction_router
from ci_signing_vault import router as ci_signing_router

app.include_router(gmail_oauth_router)
app.include_router(gmail_reconstruction_router)
app.include_router(ci_signing_router)

__all__ = ["app"]
