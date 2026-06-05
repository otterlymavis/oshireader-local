import asyncio
import logging
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.api import credentials, feed, watch_terms
from app.database import Base, SessionLocal, engine, get_db
from app.ingestion.scheduler import poll_once, scheduler, start_scheduler
from app.models import Match, SourceItem, WatchTerm

logging.basicConfig(level=logging.INFO, format="%(levelname)s  %(name)s  %(message)s")

log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncGenerator[None, None]:
    Base.metadata.create_all(bind=engine)
    start_scheduler()
    asyncio.create_task(poll_once())
    yield
    scheduler.shutdown()


app = FastAPI(title="Otterpia", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(watch_terms.router)
app.include_router(feed.router)
app.include_router(credentials.router)


@app.get("/api/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/api/admin/poll")
@app.post("/api/admin/poll")
async def trigger_poll() -> dict:
    asyncio.create_task(poll_once())
    return {"status": "poll started"}


@app.get("/api/admin/test-fetch")
async def test_fetch() -> dict:
    import httpx, feedparser
    from urllib.parse import quote
    results = {}
    kw = "星野源"
    enc = quote(f"{kw} site:mdpr.jp")
    url = f"https://news.google.com/rss/search?q={enc}&hl=ja&gl=JP&ceid=JP%3Aja"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(url)
            results["gnews_status"] = resp.status_code
            if resp.is_success:
                feed = feedparser.parse(resp.content)
                results["gnews_entries"] = len(feed.entries)
    except Exception as e:
        results["gnews_error"] = str(e)
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get("https://togetter.com/search", params={"q": kw})
            results["togetter_status"] = resp.status_code
            results["togetter_body_len"] = len(resp.text)
    except Exception as e:
        results["togetter_error"] = str(e)
    return results


@app.get("/api/admin/stats")
def get_stats(db: Session = Depends(get_db)) -> dict:
    items_total = db.query(func.count(SourceItem.id)).scalar()
    matches_total = db.query(func.count(Match.id)).scalar()
    terms = db.query(WatchTerm).all()
    by_platform = db.query(SourceItem.platform, func.count(SourceItem.id)).group_by(SourceItem.platform).all()
    return {
        "items_total": items_total,
        "matches_total": matches_total,
        "watch_terms": [{"id": t.id, "keyword": t.keyword, "is_active": t.is_active} for t in terms],
        "items_by_platform": {p: c for p, c in by_platform},
    }
