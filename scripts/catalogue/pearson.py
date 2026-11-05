#!/usr/bin/env python3
"""Pearson Edexcel: the past-paper finder on qualifications.pearson.com.

Pearson's finder page searches its documents through a hosted search service, with a search-only key it
gives every visitor in the page itself. This reads that key from the page on each run (nothing is kept
in the repo), asks for past papers, mark schemes and examiner reports, and keeps links to Pearson's own
PDFs. Running it is the user's choice (2026-11-04; .claude/settings.json allows it in Claude sessions).

Only files under /content/dam/pdf/ are kept: they're public. Newer series sit under /content/dam/secure/
and need a Pearson login (401), so they're left out. Covered: GCSE, International GCSE, AS/A level and
International AS & A Level; question papers (inserts as "data"), mark schemes, examiner reports. A spec is
kept if it has a public question paper from 2019 on and no newer spec replaces it (4CH0 → 4CH1).

    python3 scripts/catalogue/pearson.py probe     # one sample record, to see the fields
    python3 scripts/catalogue/pearson.py find      # every spec found, without writing (DOCS=3 shows some files)
    python3 scripts/catalogue/build.py pearson     # write catalogue/ (~6 minutes)
"""
import json, re, sys, os, urllib.parse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import fetch, doc_id, level_of, spec_doc  # noqa: E402

PAGE = "https://qualifications.pearson.com/en/support/support-topics/exams/past-papers.html"


def config():
    page = fetch(PAGE)
    def val(cls):
        m = re.search(rf'value="([^"]+)"\s+class="{cls}"', page)
        if not m:
            raise RuntimeError(f"{cls} not found on Pearson's page")
        return m.group(1)
    return val("algoliaAppId"), val("algoliaAPIKey"), val("algoliaIndexName")


def query(cfg, filters, page=0, per=1000, attributes=None):
    app, key, index = cfg
    import urllib.request
    body = {"query": "", "filters": filters, "hitsPerPage": per, "page": page}
    if attributes:
        body["attributesToRetrieve"] = attributes
    req = urllib.request.Request(f"https://{app}-dsn.algolia.net/1/indexes/{index}/query", data=json.dumps(body).encode(),
                                 headers={"X-Algolia-Application-Id": app, "X-Algolia-API-Key": key, "Content-Type": "application/json",
                                          "Referer": "https://qualifications.pearson.com/", "User-Agent": "Trove catalogue builder"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())



FAMILIES = {"GCSE": "GCSE", "International-GCSE": "International GCSE", "A-Level": None,
            "International-Advanced-Level": "International AS & A Level"}
KINDS = {"Question-paper": "qp", "Mark-scheme": "ms", "Examiner-report": "er"}
# Names where Pearson's subject tag is shared by two specs, or too broad.
NAMES = {"9BN0": "Biology A (Salters-Nuffield)", "8BN0": "Biology A (Salters-Nuffield)", "9BI0": "Biology B", "8BI0": "Biology B",
         "9EC0": "Economics A", "8EC0": "Economics A", "9EB0": "Economics B", "8EB0": "Economics B",
         "9FM0": "Further Mathematics", "8FM0": "Further Mathematics", "1BI0": "Biology", "1CH0": "Chemistry",
         "1PH0": "Physics", "1SC0": "Combined Science", "4SD0": "Science (Double Award)", "4SS0": "Science (Single Award)",
         "1EN2": "English Language 2.0", "1CP2": "Computer Science"}
CURRENT = 2019  # a spec with no public question paper from this year on is a legacy one
SITE = "https://qualifications.pearson.com"
FILE = re.compile(r"^([0-9][a-z]{2}[0-9])[-_]([0-9a-z]+)[-_]", re.I)       # 9ph0-01-que-…, 1MA1_1H_que_…
IAL = re.compile(r"^(w[a-z]{2})(\d)(\d)[-_]([0-9a-z]+)[-_]", re.I)           # WBI14_01_que_…, whi03-1b-que-…


def facets(cfg, filters, name):
    app, key, index = cfg
    import urllib.request
    body = {"query": "", "filters": filters, "hitsPerPage": 0, "facets": ["category"], "maxValuesPerFacet": 1000}
    req = urllib.request.Request(f"https://{app}-dsn.algolia.net/1/indexes/{index}/query", data=json.dumps(body).encode(),
                                 headers={"X-Algolia-Application-Id": app, "X-Algolia-API-Key": key, "Content-Type": "application/json",
                                          "Referer": SITE + "/", "User-Agent": "Trove catalogue builder"})
    with urllib.request.urlopen(req, timeout=60) as r:
        d = json.loads(r.read())
    pre = f"Pearson-UK:{name}/"
    return {k: v for k, v in (d.get("facets") or {}).get("category", {}).items() if k.startswith(pre) and "/" not in k[len(pre):]}


def records(cfg, filters, split=("Exam-Series", "Qualification-Subject", "Specification-Code")):
    """Every record matching `filters`; a slice too big for one page (1000) is split by a facet."""
    d = query(cfg, filters, per=1000, attributes=["url", "category", "title"])
    if d.get("nbHits", 0) <= 1000 or not split:
        return d.get("hits", [])
    out = []
    for value in facets(cfg, filters, split[0]):
        out += records(cfg, f'{filters} AND category:"{value}"', split[1:])
    return out


def tags(hit):
    t = {}
    for c in hit.get("category", []):
        if "/" in c:
            k, v = c.split(":", 1)[-1].split("/", 1)
            if k not in t or "/" in t[k] and "/" not in v:  # "ial-physics", not ".../2013/ial-physics"
                t[k] = v
    return t


def parse(hit, family):
    """One record → (spec id, spec fields, doc), or None for a locked, non-PDF or unrecognised file."""
    url = hit.get("url") or ""
    if not url.startswith("/content/dam/pdf/") or not url.lower().endswith(".pdf"):
        return None
    t = tags(hit)
    kind = KINDS.get(t.get("Document-Type"))
    name = url.rsplit("/", 1)[-1]
    if not kind:
        return None
    if re.search(r"[-_](ins|insert|res|sou|source)[-_.]", name, re.I) or re.search(r"\binsert\b|\bsource booklet\b", hit.get("title") or "", re.I):
        kind = "data" if kind == "qp" else kind
    series, year = None, None
    m = re.match(r"([A-Za-z]+)-(\d{4})$", t.get("Exam-Series") or "")
    if m:
        series, year = m.group(1).title(), int(m.group(2))
    else:
        m = re.search(r"(20\d\d)([01]\d)[0-3]\d", name)
        if m:
            year = int(m.group(1))
            series = {"01": "January", "05": "June", "06": "June", "10": "October", "11": "November"}.get(m.group(2))
    subject = (t.get("Qualification-Subject") or "").replace("-", " ").strip()
    tier = None
    if family == "International-Advanced-Level":
        m = IAL.match(name)
        if not m:
            return None
        prefix, gen, unit, rest = m.group(1).upper(), m.group(2), m.group(3), m.group(4).upper()
        group = (t.get("Specification-Code") or prefix).lower()
        sid = "pearson-" + re.sub(r"[^a-z0-9]+", "-", group)
        paper = f"{prefix}{gen}{unit}" + ("" if rest in ("01", "1") else f"-{rest[1:] if rest.startswith('1') and len(rest) == 2 else rest}")
        spec = {"qualification": FAMILIES[family], "subject": subject, "code": prefix, "level": "alevel"}
    else:
        m = FILE.match(name)
        if not m:
            return None
        code, rest = m.group(1).upper(), m.group(2).upper()
        if family == "A-Level":
            qual = {"8": "AS", "9": "A-level"}.get(code[0])
        elif family == "GCSE":
            qual = "GCSE" if code[0] == "1" else None
        else:
            qual = "International GCSE" if code[0] == "4" else None
        if not qual:
            return None
        t_ = re.fullmatch(r"\d([BCP]?)([FH])R?", rest)  # 1MA1 "1H", 4MA1 "2FR", Combined Science "1BF" (biology, foundation)
        if family != "A-Level" and t_ and (not t_.group(1) or family == "GCSE"):
            tier = "Foundation" if t_.group(2) == "F" else "Higher"
        paper = rest.lstrip("0") or rest
        sid = f"pearson-{code.lower()}"
        spec = {"qualification": qual, "subject": subject, "code": code, "level": level_of(qual)}
    title = re.sub(r"^(Question paper|Mark scheme|Examiner report)\s*-\s*", "", hit.get("title") or "", flags=re.I)
    title = re.sub(r"\s*-\s*[A-Za-z]+ \d{4}\s*$", "", re.sub(r"\s+", " ", title)).strip()
    doc = {"type": kind, "paper": paper, "tier": tier, "title": title or None, "series": series, "year": year,
           "url": SITE + urllib.parse.quote(url)}
    return sid, spec, doc


def spec_codes(hit):
    """Every Specification-Code tag on a record ("gcse-physics-2016", ".../2016/gcse-physics-2016")."""
    return {c.rsplit("/", 1)[-1] for c in hit.get("category", []) if c.startswith("Pearson-UK:Specification-Code/")}


def add_specifications(cfg, specs, codes):
    """Each course's specification PDF (learn-pivot plan §C6): Pearson's "Specification" documents, matched to a
    course through the Specification-Code tags its past papers carry (`codes`: tag → spec id). Public files only."""
    best = {}
    for family in FAMILIES:
        try:
            hits = records(cfg, f'category:"Pearson-UK:Qualification-Family/{family}" AND category:"Pearson-UK:Document-Type/Specification"')
        except Exception as e:  # noqa: BLE001
            print("pearson: specifications skipped", family, e)
            continue
        for h in hits:
            url = h.get("url") or ""
            if not url.startswith("/content/dam/pdf/") or not url.lower().endswith(".pdf"):
                continue
            name = url.rsplit("/", 1)[-1].lower()
            score = (("spec" in name) * 2 + ("issue" in name or "-iss" in name), name)  # newer issues sort later
            for tag in spec_codes(h):
                sid = codes.get(tag)
                if sid and (sid not in best or score > best[sid][0]):
                    best[sid] = (score, h.get("title") or "Specification", SITE + urllib.parse.quote(url))
    for sid, (_, title, url) in best.items():
        if sid in specs:
            specs[sid]["docs"].append(spec_doc(sid, url, re.sub(r"\s+", " ", title).strip() or "Specification"))


def find():
    cfg = config()
    specs = {}
    codes = {}
    for family in FAMILIES:
        for dt in KINDS:
            hits = records(cfg, f'category:"Pearson-UK:Qualification-Family/{family}" AND category:"Pearson-UK:Document-Type/{dt}"')
            for h in hits:
                p = parse(h, family)
                if not p:
                    continue
                sid, fields, doc = p
                for tag in spec_codes(h):
                    codes.setdefault(tag, sid)
                spec = specs.setdefault(sid, {"id": sid, "board": "pearson", **fields, "url": PAGE, "docs": []})
                doc["id"] = doc_id(sid, doc["type"], doc["paper"], doc["tier"], doc["series"], doc["year"])
                spec["docs"].append({k: v for k, v in doc.items() if v is not None})
    for s in specs.values():  # IAL Mathematics has WMA, WFM, WME, WST and WDM units: name it by the main one
        if s["qualification"].startswith("International AS"):
            prefixes = [re.match(r"[A-Z]+", d["paper"]).group(0) for d in s["docs"]]
            s["code"] = max(set(prefixes), key=prefixes.count)
    last = {sid: max([d.get("year") or 0 for d in s["docs"] if d["type"] == "qp"] or [0]) for sid, s in specs.items()}
    # A spec replaced by a newer one (4CH0 → 4CH1, 1CP1 → 1CP2, IAL Biology 2013 → 2018) is dropped:
    # same code family or, for IAL, the same subject, with question papers in a later year.
    keys = lambda s: [(s["qualification"], s["code"][:3])] + ([(s["qualification"], s["subject"])] if s["code"].startswith("W") else [])
    newest = {}
    for sid, s in specs.items():
        for k in keys(s):
            newest[k] = max(newest.get(k, 0), last[sid])
    current = [s for sid, s in specs.items() if last[sid] >= CURRENT and all(last[sid] >= newest[k] for k in keys(s))]
    for s in current:
        s["subject"] = NAMES.get(s["code"]) or (s["subject"][:1].upper() + s["subject"][1:]) or s["code"]
    add_specifications(cfg, {s["id"]: s for s in current}, codes)
    return {"id": "pearson", "name": "Pearson Edexcel", "site": SITE}, current


if __name__ == "__main__" and sys.argv[1:2] == ["probe"]:
    cfg = config()
    d = query(cfg, 'category:"Pearson-UK:Document-Type/Question-paper"', per=2)
    print("hits:", d.get("nbHits"), "pages:", d.get("nbPages"))
    print(json.dumps(d.get("hits", [])[:2], indent=1)[:4000])


if __name__ == "__main__" and sys.argv[1:2] == ["find"]:
    board, specs = find()
    print(len(specs), "specs", sum(len(s["docs"]) for s in specs), "docs")
    for s in sorted(specs, key=lambda s: (s["qualification"], s["subject"])):
        ys = [d["year"] for d in s["docs"] if d.get("year")]
        if os.environ.get("DOCS"):
            for d in s["docs"][:int(os.environ["DOCS"])]:
                print("   ", d)
        print(s["id"], "|", s["qualification"], "|", s["subject"], "|", s["code"], "|", sum(d["type"] == "qp" for d in s["docs"]), len(s["docs"]), min(ys), max(ys))
