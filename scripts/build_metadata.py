#!/usr/bin/env python3
"""Builds the metadata bundled into WUDCore (Sources/WUDCore/Resources/title_metadata.json).

Inputs (download them first; none are committed):
  --wiiubrew  saved HTML of https://wiiubrew.org/wiki/Title_database  (title ID -> product code, versions)
  --gametdb   wiiutdb.xml from https://www.gametdb.com/wiiutdb.zip?LANG=EN  (synopsis, developer, ...)
  --titles    the NUS title list (title_db.json, from extract_title_db.py or napi.v10lator.de/db?t=json)

Output shape (kept terse because it ships inside the app):
  {"titles": {"<TID>": {"g": "<GameTDB id>", "v": [versions]}},
   "games":  {"<GameTDB id>": {"t": title, "s": synopsis, "d": developer, "p": publisher, "y": year, "r": genres}}}

Cover art isn't bundled: the app fetches it from art.gametdb.com by the GameTDB id at runtime.
"""
import argparse
import html
import json
import re
import unicodedata
import xml.etree.ElementTree as ET

TID_RE = re.compile(r"^([0-9A-F]{8})-([0-9A-F]{8})$")
PRODUCT_RE = re.compile(r"^WUP-[A-Z]-([A-Z0-9]{4})$")
COMPANY_RE = re.compile(r"^[0-9A-Z]{4}$")
VERSION_RE = re.compile(r"v(\d+)\b")


def cell_text(raw):
    return html.unescape(re.sub(r"<[^>]+>", "", raw)).strip()


def parse_wiiubrew(path):
    page = open(path, encoding="utf-8").read()
    out = {}
    for row in re.findall(r"<tr>(.*?)</tr>", page, re.S):
        cells = [cell_text(c) for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
        if not cells:
            continue
        m = TID_RE.match(cells[0])
        if not m:
            continue
        tid = m.group(1) + m.group(2)
        info = out.setdefault(tid, {"name": cells[1] if len(cells) > 1 else ""})
        for i, c in enumerate(cells):
            pm = PRODUCT_RE.match(c)
            if pm and i + 1 < len(cells) and COMPANY_RE.match(cells[i + 1]):
                info["gid"] = pm.group(1) + cells[i + 1][-2:]
            if c.startswith("v") and VERSION_RE.search(c):
                vs = sorted({int(v) for v in VERSION_RE.findall(c)})
                if vs:
                    info["versions"] = vs
    return out


def norm(name):
    name = unicodedata.normalize("NFKD", name).lower()
    return re.sub(r"[^a-z0-9]+", "", name)


def parse_gametdb(path):
    games = {}
    for g in ET.parse(path).getroot().iter("game"):
        gid = (g.findtext("id") or "").strip()
        if not gid:
            continue
        title, synopsis = "", ""
        for loc in g.findall("locale"):
            if loc.get("lang") == "EN":
                title = (loc.findtext("title") or "").strip()
                synopsis = (loc.findtext("synopsis") or "").strip()
        if not title:
            loc = g.find("locale")
            title = (loc.findtext("title") or "").strip() if loc is not None else ""
        date = g.find("date")
        rec = {"t": title or g.get("name", "")}
        if synopsis:
            rec["s"] = synopsis
        for key, tag in (("d", "developer"), ("p", "publisher"), ("r", "genre")):
            val = (g.findtext(tag) or "").strip()
            if val:
                rec[key] = val
        if date is not None and (date.get("year") or "").isdigit():
            rec["y"] = int(date.get("year"))
        games[gid] = rec
    return games


# MCP region bit -> the region letter GameTDB ids carry in their 4th character.
REGION_LETTERS = {0x02: "E", 0x04: "P", 0x01: "J"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wiiubrew", required=True)
    ap.add_argument("--gametdb", required=True)
    ap.add_argument("--titles", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    brew = parse_wiiubrew(args.wiiubrew)
    tdb = parse_gametdb(args.gametdb)
    titles = json.load(open(args.titles, encoding="utf-8"))

    by_name = {}
    for gid, rec in tdb.items():
        by_name.setdefault(norm(rec["t"]), []).append(gid)

    out_titles, used = {}, set()
    matched = {"wiiubrew": 0, "name": 0}
    for t in titles:
        tid = t["TitleID"].upper()
        high = tid[:8]
        entry = {}
        b = brew.get(tid, {})
        if b.get("versions"):
            entry["v"] = b["versions"]
        if high in ("00050000", "00050002"):
            gid = b.get("gid")
            if gid in tdb:
                matched["wiiubrew"] += 1
            else:
                gid = None
                letters = [l for bit, l in REGION_LETTERS.items() if t["Region"] & bit]
                for cand in by_name.get(norm(t["Name"]), []):
                    if not letters or cand[3] in letters or cand[3] in "AXYZ":
                        gid = cand
                        matched["name"] += 1
                        break
            if gid:
                entry["g"] = gid
                used.add(gid)
        if entry:
            out_titles[tid] = entry

    # Updates carry their own version lists on wiiubrew even though they aren't in the NUS list.
    for tid, b in brew.items():
        if tid.startswith("0005000E") and b.get("versions") and tid not in out_titles:
            out_titles[tid] = {"v": b["versions"]}

    out = {"titles": out_titles, "games": {g: tdb[g] for g in sorted(used)}}
    json.dump(out, open(args.out, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    games = sum(1 for t in titles if t["TitleID"][:8] in ("00050000", "00050002"))
    print(f"{len(used)} GameTDB records for {games} games/demos; matched {matched}; {len(out_titles)} title rows")


if __name__ == "__main__":
    main()
