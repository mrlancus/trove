"""AQA: the search service behind https://www.aqa.org.uk/find-past-papers-and-mark-schemes.

It returns every past-paper resource with its qualification, spec number, title and file. Titles look
like "Question paper (Higher) : Paper 1 Non-calculator - June 2023"; modified (large print) versions,
sound files, transcripts and candidate materials are skipped.
"""
import re
from common import fetch_json, doc_id, level_of, spec_doc

SEARCH = ("https://www.aqa.org.uk/api/search?type=aqaResource&location=/find-past-papers-and-mark-schemes"
          "&prefilter=scope&scope=findPastPapers&limit=1000&page={page}")
KINDS = {"question paper": "qp", "mark scheme": "ms", "examiner report": "er", "examiners report": "er",
         "examiners' report": "er", "insert": "data"}
TITLE = re.compile(r"^(?P<kind>[^:(]+?)\s*(?P<tags>(?:\([^)]*\)\s*)*):\s*(?P<rest>.*?)\s*-\s*(?P<series>[^-]+)$")
SERIES = re.compile(r"^(?P<month>[A-Za-z]+)\s+(?P<year>\d{4})$")
# AQA prints question numbers in boxes, "0 1 . 1", and marks as "[3 marks]".
LAYOUT = {"question": r"^(\d \d)(?: \. (\d+))?(?:\s|$)", "marks": r"\[(\d+) marks?\]", "scheme": r"^(\d\d)\.(\d+)(?:\s|$)"}
PAPER = re.compile(r"\b(?:Paper|Component|Unit)\s+([0-9]+[A-Z]?)\b")


def resources():
    refs, page = {}, 1
    while True:
        d = fetch_json(SEARCH.format(page=page))
        refs.update(d.get("references", {}))
        if not d.get("results") or len(refs) >= d.get("hits", 0):
            return list(refs.values())
        page += 1


def parse(r):
    """One resource → (qualification, spec number, doc) or None."""
    quals = r.get("qualifications") or []
    asset = ((r.get("file") or {}).get("asset") or {})
    if not quals or asset.get("extension") != "pdf" or not asset.get("url"):
        return None
    qual, code = quals[0]["name"], str(quals[0].get("specificationNumber") or "")
    if not code or not re.match(r"^(GCSE|AS|A-level) ", qual):
        return None
    m = TITLE.match(r.get("title", "").replace("’", "'"))
    if not m:
        return None
    kind = KINDS.get(m["kind"].strip().lower())
    tags = [t.strip().lower() for t in re.findall(r"\(([^)]*)\)", m["tags"])]
    if not kind or any("modified" in t or "braille" in t for t in tags):
        return None
    tier = next((t.title() for t in tags if t in ("higher", "foundation")), None)
    s = SERIES.match(m["series"].strip())
    series, year = (s["month"].title(), int(s["year"])) if s else (m["series"].strip(), None)
    paper = PAPER.search(m["rest"])
    return qual, code, {"type": kind, "paper": paper.group(1) if paper else None, "tier": tier,
                        "title": m["rest"].strip(), "series": series, "year": year, "url": asset["url"]}


ALL = "https://www.aqa.org.uk/api/search?type=aqaResource&limit=1000&page={page}"
# Specification PDFs have ids like "resources.physics.specifications.AQA-7407-7408-SP-2015_PDF".
SPEC_ID = re.compile(r"specifications\.AQA-([0-9A-Z-]+?)-SP-(\d{4})")


def specifications():
    """{spec number: (first teaching year, title, url)}: the newest specification PDF for each number."""
    out, page, seen = {}, 1, 0
    while True:
        d = fetch_json(ALL.format(page=page))
        for r in (d.get("references") or {}).values():
            m = SPEC_ID.search(r.get("_id") or "")
            asset = ((r.get("file") or {}).get("asset") or {})
            if not m or asset.get("extension") != "pdf" or not asset.get("url"):
                continue
            codes = {str(q.get("specificationNumber")) for q in r.get("qualifications") or []} | set(re.findall(r"\d{4}", m.group(1)))
            for c in codes:
                if c not in out or m.group(2) > out[c][0]:
                    out[c] = (m.group(2), r.get("title") or "Specification", asset["url"])
        seen += len(d.get("results") or [])
        if not d.get("results") or seen >= d.get("hits", 0):
            return out
        page += 1


def find():
    specs = {}
    for r in resources():
        p = parse(r)
        if not p:
            continue
        qual, code, doc = p
        level, subject = qual.split(" ", 1)
        sid = f"aqa-{code}"
        spec = specs.setdefault(sid, {"id": sid, "board": "aqa", "qualification": level, "subject": subject,
                                      "code": code, "level": level_of(level),
                                      "url": "https://www.aqa.org.uk/find-past-papers-and-mark-schemes", "docs": []})
        doc["id"] = doc_id(sid, doc["type"], doc["paper"], doc["tier"], doc["series"], doc["year"])
        spec["docs"].append({k: v for k, v in doc.items() if v is not None})
    try:
        found = specifications()
    except Exception as e:  # noqa: BLE001
        print("aqa: specifications skipped", e)
        found = {}
    for sid, spec in specs.items():
        if spec["code"] in found:
            _, title, url = found[spec["code"]]
            spec["docs"].append(spec_doc(sid, url, title))
    return {"id": "aqa", "name": "AQA", "site": "https://www.aqa.org.uk", "layout": LAYOUT}, list(specs.values())
