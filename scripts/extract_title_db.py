"""Extract the baked-in NUS title database ([]TitleEntry) from an upstream WiiUDownloader
Windows (PE, amd64) build. Layout: Name string(ptr,len) TitleID u64 Region/Key/Category u8 + pad, Version int."""
import json, struct, sys

data = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", data, 0x3C)[0]
nsec = struct.unpack_from("<H", data, pe + 6)[0]
optsz = struct.unpack_from("<H", data, pe + 20)[0]
opt = pe + 24
base = struct.unpack_from("<Q", data, opt + 24)[0]
secs = []
for i in range(nsec):
    o = opt + optsz + i * 40
    name = data[o:o + 8].rstrip(b"\0").decode()
    vsize, va, rsize, rptr = struct.unpack_from("<IIII", data, o + 8)
    secs.append((name, base + va, vsize, rptr, rsize))

def v2o(addr):
    for _, va, vs, rp, rs in secs:
        if va <= addr < va + min(vs, rs):
            return rp + addr - va
    return None

REC = 40

def rec_at(off):
    if off + REC > len(data):
        return None
    p, n, tid, reg, key, cat = struct.unpack_from("<QQQBBB", data, off)
    ver = struct.unpack_from("<q", data, off + 32)[0]
    if not (0 < n < 256) or (tid >> 48) not in (0, 5, 7) or key > 9 or cat > 5 or ver < -1 or ver > 0xFFFF:
        return None
    so = v2o(p)
    if so is None:
        return None
    try:
        name = data[so:so + n].decode("utf-8")
    except UnicodeDecodeError:
        return None
    return {"Name": name, "TitleID": f"{tid:016X}", "Region": reg, "Key": key, "Category": cat, "Version": ver}

best = []
for name, va, vs, rp, rs in secs:
    if name not in (".data", ".rdata", ".noptrdata"):
        continue
    off = rp
    end = rp + rs
    while off < end:
        r = rec_at(off)
        if r is None:
            off += 8
            continue
        run = []
        o = off
        while (r := rec_at(o)) is not None:
            run.append(r)
            o += REC
        if len(run) > len(best):
            best = run
        off = o if len(run) > 1 else off + 8

print(f"{len(best)} entries", file=sys.stderr)
json.dump(best, open(sys.argv[2], "w"), ensure_ascii=False, separators=(",", ":"))
