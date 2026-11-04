"""OCR: each qualification's public Assessment page (www.ocr.org.uk/qualifications/<level>/<slug>/assessment/).

The page lists, per tab (A Level, AS Level, GCSE), "Question papers, mark schemes and reports" by series
("2024 - June series") and "Sample assessment materials", each link with its unit code ("H556/01").
OCR keeps the most recent series on Teach Cambridge for teachers, so those aren't public.
"""
import re
from common import fetch, doc_id, level_of

BASE = "https://www.ocr.org.uk"
LEVELS = {"gcse": "GCSE", "as-and-a-level": "A-level"}
TOKENS = re.compile(r'<li><h2><a id="(?P<tab>[^"]*)"|class="level-1 heading[^>]*><span>(?P<h3>[^<]*)'
                    r'|class="level-2 heading[^>]*><span>(?P<h4>[^<]*)'
                    r'|<a href="(?P<href>[^"]*\.pdf)"[^>]*>(?P<text>[^<]*)</a>\s*(?:<span class="unit-code">(?P<unit>[^<]*)</span>)?')
SERIES = re.compile(r"(\d{4})\s*-\s*([A-Za-z]+)")
KINDS = [("question paper", "qp"), ("mark scheme", "ms"), ("examiners' report", "er"), ("examiners report", "er"),
         ("insert", "data"), ("data sheet", "data"), ("formulae", "data"), ("resource booklet", "data")]
SKIP = ("erratum", "modified", "braille", "transcript", "moderators", "audio", "notice", "instructions", "guide")


def qualifications():
    out = []
    for path, level in LEVELS.items():
        html = fetch(f"{BASE}/qualifications/{path}/")
        for slug in sorted(set(re.findall(rf'href="/qualifications/{path}/([a-z0-9-]+)/"', html))):
            out.append((level, f"{BASE}/qualifications/{path}/{slug}/"))
    return out


def subject_of(html, url):
    t = re.search(r"<h1[^>]*>\s*([^<]+?)\s*</h1>", html)
    title = re.search(r"<title>\s*([^<]+?)\s*</title>", html)
    name = title.group(1) if title else (t.group(1) if t else url)
    # "OCR AS and A Level Physics A - H156, H556 (from 2015)" style; keep the subject.
    name = re.sub(r"\s*-\s*OCR\s*$", "", name)
    parts = [p.strip() for p in name.split(" - ") if p.strip() and p.strip().lower() not in ("assessment", "ocr")]
    name = parts[-2] if len(parts) >= 2 and re.search(r"[A-Z]\d{3}", parts[-1]) else (parts[-1] if parts else name)
    name = re.sub(r"^(?:OCR\s+)?(?:GCSE|AS and A Level|A Level|AS Level)\s*(?:\(9-1\))?\s*", "", name)
    name = re.sub(r"^Gateway Science Suite - |^Twenty First Century Science Suite - ", "", name)
    return name.strip() or url


def parse(html, level):
    """→ {code: [docs]} from one Assessment page."""
    docs, tab, section, series, year = {}, None, None, None, None
    for m in TOKENS.finditer(html):
        if m["tab"]:
            tab = m["tab"]
        elif m["h3"]:
            section = m["h3"].strip().lower()
            series, year = ("Sample", None) if "sample" in section else (None, None)
        elif m["h4"]:
            s = SERIES.search(m["h4"])
            if s and section and "question papers" in section:
                year, series = int(s.group(1)), s.group(2).title()
        elif m["href"] and section and ("question papers" in section or "sample" in section):
            text, unit = m["text"].strip(), (m["unit"] or "").strip()
            low = text.lower()
            kind = next((k for w, k in KINDS if low.startswith(w) or f" {w}" in low), None)
            u = re.match(r"([A-Z]\d{3})/(\w+)", unit)
            if not kind or not u or any(w in low for w in SKIP) or (series is None and "sample" not in section):
                continue
            code, paper = u.group(1), u.group(2).lstrip("0") or "0"
            tier = "Higher" if "higher" in low else "Foundation" if "foundation" in low else None
            title = text.split(" - ", 1)[1] if " - " in text else text
            href = m["href"] if m["href"].startswith("http") else BASE + m["href"]
            docs.setdefault(code, []).append({"type": kind, "paper": paper, "tier": tier, "title": title,
                                              "series": series, "year": year, "url": href})
    return docs


def as_codes(url):
    """AS codes from the slug: "physics-a-h156-h556-from-2015" lists AS codes first (H156 AS, H556 A Level)."""
    codes = sorted(re.findall(r"-(h\d{3})(?=-)", url))
    return set(codes[: len(codes) // 2]) if len(codes) >= 2 else set()


def find():
    specs = []
    for level, url in qualifications():
        try:
            html = fetch(url + "assessment/")
        except Exception as e:  # noqa: BLE001
            print("ocr: skipped", url, e)
            continue
        subject = subject_of(html, url)
        # Units with their own codes (History A's Y100–Y3xx, Further Maths' Y5xx) belong to the qualification
        # on the page: grouped under its A Level (or GCSE) code, the unit code kept in the paper.
        own = [c.upper() for c in re.findall(r"-([hj]\d{3})(?=-)", url)]
        grouped = {}
        for code, docs in parse(html, level).items():
            if own and code not in own:
                for d in docs:
                    d["paper"] = f"{code}/{d['paper']}"
                code = own[-1]
            grouped.setdefault(code, []).extend(docs)
        for code, docs in grouped.items():
            qual = "GCSE" if level == "GCSE" else ("AS" if code.lower() in as_codes(url) else "A-level")
            sid = f"ocr-{code.lower()}"
            for d in docs:
                d["id"] = doc_id(sid, d["type"], d["paper"], d["tier"], d["series"], d["year"])
            specs.append({"id": sid, "board": "ocr", "qualification": qual, "subject": subject, "code": code,
                          "level": level_of(qual), "url": url,
                          "docs": [{k: v for k, v in d.items() if v is not None} for d in docs]})
    return {"id": "ocr", "name": "OCR", "site": BASE}, specs
