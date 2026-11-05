"""WJEC (Wales) and Eduqas (England): the same site engine.

The home page (WJEC) or the past-papers page (Eduqas) carries the qualification list as JSON. Each
qualification page's "Past papers" tab is loaded from /umbraco/surface/TabSurface/GetpastpapersTab with
the page's QualificationId; it returns every past paper and mark scheme as JSON with its file URL on
pastpapers.download.wjec.co.uk. File names carry the unit code: Eduqas A420U10-1 (A level), B420 (AS),
C420 (GCSE); WJEC 1420 (A level), 2420 (AS), 3420 (GCSE). Legacy specs (8420-01) are skipped.
"""
import html as htmllib, json, re
from common import fetch, doc_id, level_of, spec_doc

SITES = {"eduqas": ("Eduqas", "https://www.eduqas.co.uk", "/home/past-papers-and-mark-schemes/"),
         "wjec": ("WJEC", "https://www.wjec.co.uk", "/")}
UNIT = re.compile(r"(?<![A-Za-z0-9])([ABC1-3])(\d{3})U([0-9A-Z])([0-9A-Z])(?:-(\d))?", re.I)
QUAL = {"a": "A-level", "1": "A-level", "b": "AS", "2": "AS", "c": "GCSE", "3": "GCSE"}
KINDS = {"past paper": "qp", "mark scheme": "ms", "examiner report": "er", "examiners report": "er"}


def props(page):
    for t in re.findall(r'<textarea class="react-component--props">(.*?)</textarea>', page, re.S):
        try:
            yield json.loads(htmllib.unescape(t))
        except ValueError:
            continue


def qualifications(base, path):
    for d in props(fetch(base + path)):
        if "qualifications" in d:
            return [q for q in d["qualifications"] if re.search(r"\b(GCSE|AS/A Level|AS and A Level|A Level)\b", q["name"])
                    and "withdrawn" not in q["name"].lower() and not q.get("isLegacy")]
    return []


def ids(page):
    qid = re.search(r'id="QualificationId"[^>]*value="([^"]*)"', page) or re.search(r'value="([^"]*)"[^>]*id="QualificationId"', page)
    cid = re.search(r'id="CultureId"[^>]*value="([^"]*)"', page) or re.search(r'value="([^"]*)"[^>]*id="CultureId"', page)
    return (qid.group(1) if qid else None), (cid.group(1) if cid else "en-GB")


def walk(x):
    if isinstance(x, dict):
        yield x
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)


def specifications(base, qid, cid):
    """The "Key documents" tab: entries with DocumentType "Specification" → [(name, url)]."""
    out = []
    tab = fetch(f"{base}/umbraco/surface/TabSurface/GetkeydocumentsTab?qualificationId={qid}&cultureId={cid}")
    for d in props(tab):
        for x in walk(d):
            if x.get("DocumentType") == "Specification" and str(x.get("Link") or "").lower().endswith(".pdf"):
                link = x["Link"]
                out.append((x.get("Name") or "Specification", link if link.startswith("http") else base + link))
    return out


def spec_for(found, qual):
    """Picks the specification for "A-level", "AS" or "GCSE" by its name ("AS Level Physics Specification")."""
    if len(found) == 1:
        return found[0]
    def level(name):
        n = name.lower()
        return "AS" if re.search(r"\bas\b(?! and)", n) else "GCSE" if "gcse" in n else "A-level" if "a level" in n else None
    for name, url in found:
        if level(name) == qual:
            return name, url
    return None


def items(base, link):
    page = fetch(base + link)
    qid = re.search(r'id="QualificationId"[^>]*value="([^"]*)"', page) or re.search(r'value="([^"]*)"[^>]*id="QualificationId"', page)
    cid = re.search(r'id="CultureId"[^>]*value="([^"]*)"', page) or re.search(r'value="([^"]*)"[^>]*id="CultureId"', page)
    if not qid:
        return []
    tab = fetch(f"{base}/umbraco/surface/TabSurface/GetpastpapersTab?qualificationId={qid.group(1)}&cultureId={cid.group(1) if cid else 'en-GB'}")
    for d in props(tab):
        if "listItems" in d:
            return d["listItems"]
    return []


def parse(item, known=None):
    """One listed file → (spec code, doc). Older files named "s17-8421-01.pdf" carry no unit code; they're
    placed by their component title, learned from the files that do (`known`: title → (code, paper))."""
    kind = KINDS.get((item.get("ProductReference") or "").strip().lower())
    url = (item.get("Url") or "").strip()
    name = (item.get("FileName") or "").replace("&", "and")
    u = UNIT.search(url.rsplit("/", 1)[-1])
    if not kind or not url.lower().endswith(".pdf") or "[resource]" in name.lower() and kind != "qp":
        return None
    if u:
        code = f"{u.group(1).upper()}{u.group(2)}"
        paper = u.group(3).upper() if u.group(3) != "0" else u.group(4).upper()
    elif known is not None and component_key(name) in known:
        code, paper = known[component_key(name)]
    else:
        return None
    title = re.sub(r"^[^-]+-\s*[^-]+-\s*", "", name)
    title = title.split(":", 1)[-1].strip() if ":" in title else title
    resource = "[resource]" in name.lower()
    tier = "Higher" if re.search(r"higher", name, re.I) else "Foundation" if re.search(r"foundation", name, re.I) else None
    year = int(item["Year"]) if str(item.get("Year") or "").isdigit() else None
    return code, {"type": "data" if resource else kind, "paper": paper, "tier": tier,
                  "title": re.sub(r"\s*\[[^\]]*\]", "", title).strip(), "series": (item.get("Series") or "").title() or None,
                  "year": year, "url": url.replace(" ", "%20")}


def component_key(name):
    """"Past Paper - Summer - GCE AS Physics Component 1 Motion, Energy:Motion, Energy and Matter" →
    "1 motion, energy and matter" (what's after the colon names the component)."""
    n = re.search(r"Component\s+(\w+)", name)
    rest = name.split(":", 1)[-1] if ":" in name else name
    rest = re.sub(r"\s*\[[^\]]*\]", "", rest).strip().lower()
    return f"{n.group(1) if n else ''} {rest}"


def find_site(board):
    name, base, path = SITES[board]
    specs = {}
    for q in qualifications(base, path):
        try:
            listed = items(base, q["link"])
        except Exception as e:  # noqa: BLE001
            print(board, "skipped", q["link"], e)
            continue
        subject = re.sub(r"\s*(GCSE|AS/A Level|AS and A Level|A Level).*$", "", q["name"]).strip()
        try:
            qid, cid = ids(fetch(base + q["link"]))
            found_specs = specifications(base, qid, cid) if qid else []
        except Exception:  # noqa: BLE001
            found_specs = []
        before = set(specs)
        known = {}
        for it in listed:
            p = parse(it)
            if p:
                known.setdefault(component_key((it.get("FileName") or "").replace("&", "and")), (p[0], p[1]["paper"]))
        for it in listed:
            p = parse(it, known)
            if not p:
                continue
            code, doc = p
            qual = QUAL[code[0].lower()]
            sid = f"{board}-{code.lower()}"
            spec = specs.setdefault(sid, {"id": sid, "board": board, "qualification": qual, "subject": subject,
                                          "code": code, "level": level_of(qual), "url": base + q["link"], "docs": []})
            doc["id"] = doc_id(sid, doc["type"], doc["paper"], doc["tier"], doc["series"], doc["year"])
            spec["docs"].append({k: v for k, v in doc.items() if v is not None})
        for sid in set(specs) - before:
            pick = spec_for(found_specs, specs[sid]["qualification"])
            if pick:
                specs[sid]["docs"].append(spec_doc(sid, pick[1], pick[0]))
    return {"id": board, "name": name, "site": base}, list(specs.values())


def find_eduqas():
    return find_site("eduqas")


def find_wjec():
    return find_site("wjec")
