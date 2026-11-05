"""Cambridge International: IGCSE and International AS & A Level syllabus pages.

Each syllabus has a public past-papers page (…/<syllabus>/past-papers/) with one recent series and the
specimen papers; everything older is on Cambridge's School Support Hub for schools, so it isn't here.
Link texts look like "June 2024 Question Paper 11", "June 2024 Mark Scheme Paper 11",
"June 2024 Examiner Report", "2022 Specimen Paper 1".
"""
import re
import datetime
from common import fetch, doc_id, level_of, spec_doc

BASE = "https://www.cambridgeinternational.org"
LISTS = {"IGCSE": "/programmes-and-qualifications/cambridge-upper-secondary/cambridge-igcse/subjects/",
         "International AS & A Level": "/programmes-and-qualifications/cambridge-advanced/cambridge-international-as-and-a-levels/subjects/"}
LINK = re.compile(r'<a href="([^"]*\.pdf)"[^>]*>(.*?)</a>', re.S)
DATED = re.compile(r"^(?P<month>[A-Za-z]+)\s+(?P<year>\d{4})\s+(?P<what>.*)$")
SPECIMEN = re.compile(r"^(?P<year>\d{4})(?:\s*-\s*\d{4})?\s+Specimen\s+(?P<what>.*)$", re.I)


def syllabuses():
    out = []
    for qual, path in LISTS.items():
        html = fetch(BASE + path)
        for slug in sorted(set(re.findall(r'href="/programmes-and-qualifications/(cambridge-[a-z-]+-(\d{4}))/"', html))):
            out.append((qual, slug[0], slug[1]))
    return out


def classify(what):
    w = what.lower()
    if any(s in w for s in ("confidential", "instructions", "insert", "transcript", "audio", "pre-release", "source files")):
        return None, None
    paper = re.search(r"paper\s+(\d+)", w)
    if "mark scheme" in w:
        kind = "ms"
    elif "examiner report" in w or "examiners report" in w:
        kind = "er"
    elif "question paper" in w or re.match(r"^paper\s+\d", w):
        kind = "qp"
    else:
        return None, None
    return kind, paper.group(1) if paper else None


def parse(html):
    docs = []
    for href, text in LINK.findall(html):
        t = re.sub(r"<[^>]+>|-->|\s+", " ", text)
        t = re.sub(r"\(PDF[^)]*\)", "", t).strip()
        m, s = DATED.match(t), SPECIMEN.match(t)
        if s:
            series, year, what = "Specimen", int(s["year"]), s["what"]
        elif m and m["month"].lower() in ("june", "november", "march", "february"):
            series, year, what = m["month"].title(), int(m["year"]), m["what"]
        else:
            continue
        kind, paper = classify(what)
        if not kind:
            continue
        docs.append({"type": kind, "paper": paper, "series": series, "year": year, "title": f"Paper {paper}" if paper else None,
                     "url": href if href.startswith("http") else BASE + href})
    return docs


SYLLABUS = re.compile(r'href="([^"]*?-(\d{4})(?:-(\d{4}))?-syllabus\.pdf)"', re.I)


def syllabus(html, year=None):
    """The syllabus PDF for this year from the syllabus page ("595430-2023-2025-syllabus.pdf"; updates skipped):
    the one whose years include `year`, else the newest that has started, else the earliest."""
    year = year or datetime.date.today().year
    found = []
    for href, start, end in SYLLABUS.findall(html):
        url = href if href.startswith("http") else BASE + href
        found.append((int(start), int(end or start), url))
    if not found:
        return None
    for start, end, url in sorted(found, reverse=True):
        if start <= year <= end:
            return url
    started = [f for f in found if f[0] <= year]
    return (max(started) if started else min(found))[2]


def find():
    specs = []
    for qual, slug, code in syllabuses():
        try:
            html = fetch(f"{BASE}/programmes-and-qualifications/{slug}/past-papers/")
        except Exception as e:  # noqa: BLE001
            print("cie: skipped", slug, e)
            continue
        title = re.search(r"<title>\s*([^<]+?)\s*</title>", html)
        name = title.group(1) if title else slug
        subject = re.sub(r"^Cambridge (?:IGCSE|International AS & A Level|O Level)\s*(?:\(9-1\))?\s*", "", name)
        subject = re.sub(r"\s*\(\d{4}\)\s*$", "", subject).strip()
        docs = parse(html)
        if not docs:
            continue
        sid = f"cie-{code}"
        for d in docs:
            d["id"] = doc_id(sid, d["type"], d["paper"], None, d["series"], d["year"])
        try:
            url = syllabus(fetch(f"{BASE}/programmes-and-qualifications/{slug}/"))
        except Exception:  # noqa: BLE001
            url = None
        if url:
            docs.append(spec_doc(sid, url, "Syllabus"))
        specs.append({"id": sid, "board": "cie", "qualification": qual, "subject": subject, "code": code,
                      "level": "igcse" if qual == "IGCSE" else "alevel",
                      "url": f"{BASE}/programmes-and-qualifications/{slug}/",
                      "docs": [{k: v for k, v in d.items() if v is not None} for d in docs]})
    return {"id": "cie", "name": "Cambridge International", "site": BASE}, specs
