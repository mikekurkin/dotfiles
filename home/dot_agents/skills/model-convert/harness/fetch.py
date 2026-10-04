"""Download a catalogue into a part library.

Source-agnostic: it takes a JSON manifest, not a scraped page. Each entry is

    {"code": "ABC.123", "name": "human readable", "url": "/path/or/full/url"}

and optionally "section". Relative urls are joined to --base.

Always extracts via zipfile rather than unzip: archives in the wild store
member names in CP866/CP1251, which Info-ZIP refuses outright, and the names
inside often carry an internal designation that is normalised away here.
Plain (non-zip) downloads are saved as-is.

  fetch.py manifest.json ~/lib "Group name" --base https://example.com
"""
import io, json, os, re, subprocess, sys, time, zipfile

args = [a for a in sys.argv[1:] if not a.startswith("--")]
opts = dict(a.split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
catalogue_file, lib = args[0], args[1]
group = args[2] if len(args) > 2 else ""
BASE = opts.get("--base", "")
REF = opts.get("--referer", BASE)
UA = opts.get("--ua", "Mozilla/5.0")
parts = json.load(open(catalogue_file, encoding="utf-8"))
os.makedirs(lib, exist_ok=True)

EXTS = set(filter(None, opts.get(
    "--exts",
    "step stp iges igs brep brp stl obj ply amf 3mf off nas bms ifc").split()))

ok = skipped = 0
for part in parts:
    code = part["code"]
    dest = os.path.join(lib, code, "stp")
    os.makedirs(dest, exist_ok=True)

    url = part["url"]
    if not url.startswith(("http://", "https://")):
        url = BASE.rstrip("/") + "/" + url.lstrip("/")
    cmd = ["curl", "-sSL", "--max-time", "180", "-A", UA]
    if REF:
        cmd += ["-e", REF]
    blob = subprocess.run(cmd + [url], capture_output=True).stdout
    if not blob:
        print("SKIP %s (empty response)" % code)
        skipped += 1
        continue

    if blob[:2] != b"PK":
        # Not an archive: save the single file under the part code.
        ext = os.path.splitext(url.split("?")[0])[1] or ".dat"
        with open(os.path.join(dest, code + ext), "wb") as fh:
            fh.write(blob)
        json.dump({"code": code, "name": " ".join(part["name"].split()),
                   "source": url, "group": part.get("section", group),
                   "files": 1},
                  open(os.path.join(lib, code, "part.json"), "w"),
                  ensure_ascii=False, indent=2)
        print("OK %s (1 file, not an archive)" % code)
        ok += 1
        continue

    seen, n = set(), 0
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        for info in zf.infolist():
            raw = info.filename.encode("cp437", errors="replace")
            name = None
            for enc in ("utf-8", "cp866", "cp1251", "latin-1"):
                try:
                    name = raw.decode(enc)
                    break
                except UnicodeDecodeError:
                    continue
            name = name or info.filename
            if name.endswith("/") or not os.path.splitext(name)[1]:
                continue
            if EXTS and os.path.splitext(name)[1].lower().lstrip(".") not in EXTS:
                continue
            # Strip the extension BEFORE matching: ".stp" is itself a dotted
            # alphanumeric group and would be swallowed into the stem, giving
            # files named foo.stp.stp.
            bare = os.path.splitext(os.path.basename(name))[0]
            match = re.search(re.escape(code) + r"(\.[0-9A-Za-z]+)*", bare)
            stem = match.group(0) if match else re.sub(
                r"[^0-9A-Za-z._-]+", "_", bare)
            clean = stem
            i = 2
            while clean in seen:
                clean = "%s_%d" % (stem, i)
                i += 1
            seen.add(clean)
            with open(os.path.join(dest, clean + os.path.splitext(name)[1].lower()), "wb") as fh:
                fh.write(zf.read(info))
            n += 1

    meta = {"code": code, "name": " ".join(part["name"].split()),
            "source": url, "group": part.get("section", group), "files": n}
    meta.update({k[2:]: v for k, v in opts.items()
                 if k not in ("--base", "--referer", "--ua", "--exts")})
    json.dump(meta,
              open(os.path.join(lib, code, "part.json"), "w"),
              ensure_ascii=False, indent=1)
    print("OK %s (%d models)" % (code, n))
    ok += 1
    time.sleep(0.4)

print("=== %d parts, %d skipped" % (ok, skipped))
