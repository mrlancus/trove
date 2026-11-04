"""Shared helpers for the exam-board finders (docs/CATALOGUE.md).

Each finder reads a board's own public past-paper listing and returns specs in the catalogue's shape:
links and facts only, never documents. Standard library only, so CI needs no installs.
"""
import json, re, time, urllib.request

UA = "Trove catalogue builder (+https://github.com/mrlancus/trove)"
MONTHS = {"january": "01", "february": "02", "march": "03", "may": "05", "june": "06", "summer": "06",
          "october": "10", "autumn": "11", "november": "11", "winter": "01", "spring": "03"}


def fetch(url, data=None, tries=3):
    """GET (or POST `data`) with a polite pause and a couple of retries."""
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, "Accept": "*/*"})
            with urllib.request.urlopen(req, timeout=60) as r:
                body = r.read()
            time.sleep(0.3)
            return body.decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(2 * (attempt + 1))
    raise last


def fetch_json(url):
    return json.loads(fetch(url))


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def series_code(series, year):
    """("June", 2023) → "2023-06"; specimens and unknown series → a slug."""
    if year is None:
        return slug(series or "specimen")
    m = MONTHS.get((series or "").strip().lower())
    return f"{year}-{m}" if m else f"{year}-{slug(series or 'x')}"


def doc_id(spec_id, kind, paper=None, tier=None, series=None, year=None):
    """Stable ids: problems point at "cat:<doc id>", so the same paper keeps the same id every build."""
    parts = [spec_id]
    if paper:
        parts.append(slug(paper))
    if tier:
        parts.append(tier.lower()[0])
    if kind != "spec":
        parts.append(series_code(series, year))
    parts.append(kind)
    return "-".join(parts)


def level_of(qualification):
    q = qualification.lower()
    if "igcse" in q or "international gcse" in q:
        return "igcse"
    if "gcse" in q:
        return "gcse"
    return "alevel"


def dedupe(docs):
    """Unique ids. The same URL twice is one doc; different files that share an id (History's option
    papers are all "Paper 1"; a paper can have two inserts) each get their title, or failing that a
    hash of their URL, added, so ids stay stable from build to build."""
    import hashlib
    by_id = {}
    for d in docs:
        group = by_id.setdefault(d["id"], [])
        if all(g["url"] != d["url"] for g in group):
            group.append(d)
    out = []
    for i, group in by_id.items():
        if len(group) == 1:
            out.append(group[0])
            continue
        used = set()
        for d in group:
            new = f"{i}-{slug(d.get('title') or '')[:48]}".rstrip("-")
            if new in used or new == i:
                new = f"{i}-{hashlib.sha256(d['url'].encode()).hexdigest()[:6]}"
            used.add(new)
            out.append(d | {"id": new})
    return out


def sort_docs(docs):
    order = {"spec": 0, "qp": 1, "data": 2, "ms": 3, "er": 4}
    return sorted(docs, key=lambda d: (-(d.get("year") or 0), d.get("series") or "", d.get("paper") or "",
                                       d.get("tier") or "", order.get(d["type"], 9)))
