#!/usr/bin/env python3
"""Pearson Edexcel: the past-paper finder on qualifications.pearson.com.

Pearson's finder page searches its documents through a hosted search service, with a search-only key it
gives every visitor in the page itself. This reads that key from the page on each run (nothing is kept
in the repo), asks for past papers, mark schemes and examiner reports, and keeps links to Pearson's own
PDFs. Running it is the user's choice (2026-11-04; .claude/settings.json allows it in Claude sessions).

Each record carries tags ("Pearson-UK:<facet>/<value>"): Qualification-Family, Qualification-Subject,
Document-Type, Exam-Series ("June-2022"), Unit ("Paper-1F", "Unit-4B") and Specification-Code
("GCSE/2015/gcse15-maths"). Papers under /content/dam/secure/ need a Pearson login, so only the public
/content/dam/pdf/ ones are kept. Specs with nothing since 2019 (the old modular ones) are left out.

    python3 scripts/catalogue/pearson.py probe     # one sample record, to see the fields
    python3 scripts/catalogue/build.py pearson     # the real thing
"""
import collections, json, re, sys, os, time, urllib.request
from urllib.parse import quote
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import fetch, doc_id, slug  # noqa: E402

SITE = "https://qualifications.pearson.com"
PAGE = SITE + "/en/support/support-topics/exams/past-papers.html"
PREFIX = "Pearson-UK:"
# Qualification family → (qualification, level). A-Level splits into AS and A level by spec code below.
FAMILIES = {"GCSE": ("GCSE", "gcse"), "International-GCSE": ("International GCSE", "igcse"),
            "A-Level": ("A level", "alevel"), "International-Advanced-Level": ("International A level", "alevel")}
TYPES = {"Question-paper": "qp", "Mark-scheme": "ms", "Examiner-report": "er"}
SERIES = re.compile(r"^(January|February|March|May|June|October|November)-(\d{4})$")
CODE = re.compile(r"^(\d[a-z]{2}\d)[-_]", re.I)          # 1ma1-1f-que…, 9PH0_02_que…, 4ea1-01r-que…
IAL_UNIT = re.compile(r"^(w[a-z]{2})(\d\d)[-_]([0-9a-z]+)[-_]", re.I)  # wma11-01-que…, WHI04_1B_que…
FILE_PAPER = re.compile(r"^\d[a-z]{2}\d[-_](\d+[a-z]?)[-_]", re.I)
RECENT = 2020
# Codes filed under one shared spec ("Science", "Mathematics") that are their own subjects.
SUBJECTS = {"1BI0": "Biology", "1CH0": "Chemistry", "1PH0": "Physics", "1SC0": "Combined Science",
            "9FM0": "Further Mathematics", "8FM0": "Further Mathematics", "9MA0": "Mathematics", "8MA0": "Mathematics"}
AGENT = "Trove catalogue builder (+https://github.com/mrlancus/trove)"


def config():
    page = fetch(PAGE)
    def val(cls):
        m = re.search(rf'value="([^"]+)"\s+class="{cls}"', page)
        if not m:
            raise RuntimeError(f"{cls} not found on Pearson's page")
        return m.group(1)
    return val("algoliaAppId"), val("algoliaAPIKey"), val("algoliaIndexName")


def query(cfg, filters, page=0, per=1000, attributes=None, facets=None):
    app, key, index = cfg
    body = {"query": "", "filters": filters, "hitsPerPage": per, "page": page}
    if attributes:
        body["attributesToRetrieve"] = attributes
    if facets:
        body |= {"facets": facets, "maxValuesPerFacet": 1000}
    req = urllib.request.Request(f"https://{app}-dsn.algolia.net/1/indexes/{index}/query", data=json.dumps(body).encode(),
                                 headers={"X-Algolia-Application-Id": app, "X-Algolia-API-Key": key, "Content-Type": "application/json",
                                          "Referer": SITE + "/", "User-Agent": AGENT})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                out = json.loads(r.read())
            time.sleep(0.1)
            return out
        except Exception:  # noqa: BLE001
            if attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))


def records(cfg):
    """Every past paper, mark scheme and examiner report in the four families. The service returns at
    most 1,000 hits a query, so it asks per spec, and per series for the specs with more."""
    out = {}
    attrs = ["url", "title", "category"]
    for fam in FAMILIES:
        types = " OR ".join(f'category:"{PREFIX}Document-Type/{t}"' for t in TYPES)
        base = f'category:"{PREFIX}Qualification-Family/{fam}" AND ({types})'
        facets = query(cfg, base, per=0, facets=["category"])["facets"]["category"]
        codes = {c: n for c, n in facets.items() if c.startswith(PREFIX + "Specification-Code/") and c.count("/") == 1}
        for code, n in codes.items():
            filt = f'{base} AND category:"{code}"'
            if n <= 1000:
                hits = query(cfg, filt, attributes=attrs)["hits"]
            else:
                inner = query(cfg, filt, per=0, facets=["category"])["facets"]["category"]
                hits = []
                for s in (c for c in inner if c.startswith(PREFIX + "Exam-Series/")):
                    hits += query(cfg, f'{filt} AND category:"{s}"', attributes=attrs)["hits"]
            for h in hits:
                out[h["url"]] = h
    return list(out.values())


def tags(record):
    t = collections.defaultdict(list)
    for c in record.get("category") or []:
        if c.startswith(PREFIX) and "/" in c:
            facet, value = c[len(PREFIX):].split("/", 1)
            t[facet].append(value)
    return t


def parse(record):
    """One record → (spec key, spec facts, doc) or None."""
    url = record.get("url") or ""
    if not url.lower().endswith(".pdf") or not url.startswith("/content/dam/pdf/"):
        return None
    t = tags(record)
    fams = [f for f in t["Qualification-Family"] if f in FAMILIES]
    kinds = [TYPES[d] for d in t["Document-Type"] if d in TYPES]
    series = next((SERIES.match(s) for s in t["Exam-Series"] if SERIES.match(s)), None)
    if not fams or not kinds or not series:
        return None
    fam = fams[0]
    # "GCSE/2015/gcse15-maths": this family's spec; the newest if a record is filed under several.
    specs = sorted((s.split("/") for s in t["Specification-Code"] if s.count("/") == 2 and s.startswith(fam + "/")),
                   key=lambda p: (fam != "International-Advanced-Level" and p[2].startswith("ial"), -int(p[1]) if p[1].isdigit() else 0))
    if not specs:
        return None
    _, accredited, spec_slug = specs[0]
    if spec_slug.endswith("-mod"):  # modified (large-print) papers
        return None
    file = url.rsplit("/", 1)[1]
    code = CODE.match(file)
    qual, level = FAMILIES[fam]
    if fam == "A-Level" and code and code.group(1)[0] == "8":
        qual = "AS"
    elif fam == "A-Level" and re.search(r"\bAS\b", record.get("title") or ""):
        qual = "AS"
    # The file name is the most exact ("9hi0-1a-que…": paper 1A); the Unit tag ("Paper-2") otherwise.
    paper = None
    if fp := FILE_PAPER.match(file):
        paper = fp.group(1).lstrip("0").upper() or None
    unit = next(iter(t["Unit"]), None)
    if not paper and (m := re.match(r"^(?:Paper|Unit|Component)-(\w+)$", unit or "", re.I)):
        paper = m.group(1).upper()
    tier = None
    if paper and level in ("gcse", "igcse") and (pm := re.match(r"^(\d+)([FH])(R?)$", paper)):
        paper, tier = pm.group(1) + pm.group(3), "Foundation" if pm.group(2) == "F" else "Higher"
    unit_code = IAL_UNIT.match(file)
    title = f"Paper {paper}" if paper else None
    if fam == "International-Advanced-Level" and unit_code:
        # International A level papers are units with their own codes ("WMA11"); options ("1B") go in the title.
        paper = (unit_code.group(1) + unit_code.group(2)).upper()
        option = unit_code.group(3).upper()
        title = f"Unit {paper}" + ("" if option in ("01", "1") else f" option {option}")
    subject = " ".join(t["Qualification-Subject"][0].split("-")) if t["Qualification-Subject"] else spec_slug
    doc = {"type": kinds[0], "paper": paper, "tier": tier, "title": title,
           "series": series.group(1), "year": int(series.group(2)), "url": SITE + quote(url)}
    facts = {"family": fam, "qualification": qual, "level": level, "subject": subject, "accredited": accredited,
             "slug": spec_slug, "code": code.group(1).upper() if code else None,
             "unit": unit_code.group(1).upper() if unit_code else None}
    return (fam, spec_slug), facts, doc


def build(hits):
    """One spec per spec code (1MA1, 9PH0, 4MA1): Pearson files some codes under one shared spec and
    some under two; files without a code join their spec's commonest code. International A levels,
    whose papers are units (WPH11…), are one spec per Pearson spec."""
    parsed = [p for p in map(parse, hits) if p]
    usual = collections.defaultdict(collections.Counter)
    for (fam, spec_slug), f, _ in parsed:
        if f["code"] and fam != "International-Advanced-Level":
            usual[(fam, spec_slug)][f["code"]] += 1
    groups = {}
    for (fam, spec_slug), f, doc in parsed:
        code = None if fam == "International-Advanced-Level" else (f["code"] or next(iter(usual[(fam, spec_slug)].most_common(1)), (None,))[0])
        g = groups.setdefault((fam, code or spec_slug), {"facts": [], "docs": [], "code": code})
        g["facts"].append(f)
        g["docs"].append(doc)
    specs, used = [], set()
    for (fam, name), g in sorted(groups.items()):
        qps = [d for d in g["docs"] if d["type"] == "qp"]
        if not qps or max(d["year"] for d in qps) < RECENT:
            continue
        facts = g["facts"]
        commonest = lambda k: collections.Counter(x[k] for x in facts).most_common(1)[0][0]  # noqa: E731
        qual, level = FAMILIES[fam]
        if fam == "A-Level":
            qual = "AS" if (g["code"] or "")[:1] == "8" or (not g["code"] and commonest("qualification") == "AS") else "A level"
        if fam == "International-Advanced-Level":
            units = sorted({x["unit"] for x in facts if x["unit"]})
            numbers = sorted({d["paper"] for d in g["docs"] if d.get("paper") and d["paper"][:3] in units})
            if len(units) == 1 and numbers:
                code = numbers[0] if len(numbers) == 1 else f"{numbers[0]}–{numbers[-1]}"
            else:
                code = "/".join(units) if units else name.upper()
            sid = f"pearson-{slug(name)}"
        else:
            code = g["code"] or name
            sid = f"pearson-{slug(code)}"
        if sid in used:
            sid = f"{sid}-{commonest('accredited')}"
        used.add(sid)
        subject = SUBJECTS.get(g["code"] or "", commonest("subject"))
        subject = subject[:1].upper() + subject[1:]
        if fam == "GCSE" and (g["code"] or "").startswith("3"):
            subject += " (Short Course)"
        docs = []
        for d in g["docs"]:
            d["id"] = doc_id(sid, d["type"], d["paper"], d["tier"], d["series"], d["year"])
            docs.append({k: v for k, v in d.items() if v is not None})
        specs.append({"id": sid, "board": "pearson", "qualification": qual, "subject": subject, "code": code,
                      "level": level, "url": PAGE, "docs": docs})
    return specs


def find():
    specs = build(records(config()))
    return {"id": "pearson", "name": "Pearson Edexcel", "site": SITE}, specs


if __name__ == "__main__" and sys.argv[1:2] == ["probe"]:
    cfg = config()
    d = query(cfg, f'category:"{PREFIX}Document-Type/Question-paper"', per=2)
    print("hits:", d.get("nbHits"), "pages:", d.get("nbPages"))
    print(json.dumps(d.get("hits", [])[:2], indent=1)[:4000])
elif __name__ == "__main__" and sys.argv[1:2] == ["offline"]:
    # python3 pearson.py offline <records.json>: build from saved records, print a summary.
    specs = build(json.load(open(sys.argv[2])))
    for s in specs:
        qps = [d for d in s["docs"] if d["type"] == "qp"]
        print(s["id"], "|", s["qualification"], s["subject"], s["code"], len(qps), len(s["docs"]),
              min(d["year"] for d in qps), max(d["year"] for d in qps))
    print(len(specs), "specs", sum(len(s["docs"]) for s in specs), "docs")
