#!/usr/bin/env python3
"""Torrent safety checks.

  inspect.py plan  <file.torrent> [all]  -> stdout: torrent name, aria2 --select-file list, selected bytes
  inspect.py files <file.torrent>        -> stdout: JSON file list for the app's picker
  inspect.py check <path>                -> quarantine every file, report anything that isn't plain media

Only reads file bytes; never opens or runs anything it inspects.
"""
import os, sys, time, json, subprocess
from datetime import datetime

BASE = os.environ.get("PURRLOAD_HOME", os.path.expanduser("~/Library/Application Support/Purrload"))
MEDIA = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".webm", ".ts", ".m2ts", ".wmv", ".flv", ".mpg",
         ".mpeg", ".mka", ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav"}
SUBS = {".srt", ".ass", ".ssa", ".vtt", ".sub", ".idx", ".sup"}
HARMLESS = {".nfo", ".txt", ".jpg", ".jpeg", ".png", ".webp", ".sfv", ".md5"}
DANGEROUS = {".app", ".dmg", ".pkg", ".mpkg", ".command", ".sh", ".tool", ".scpt", ".applescript",
             ".terminal", ".workflow", ".exe", ".msi", ".bat", ".cmd", ".ps1", ".vbs", ".js", ".jar",
             ".lnk", ".scr", ".com", ".dll", ".py", ".pl", ".rb", ".bin", ".iso", ".url", ".webloc"}
ARCHIVES = {".zip", ".rar", ".7z", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".r00", ".001"}
BAIT = ("codec", "player", "setup", "install", "crack", "keygen", "password", "activator",
        "readme first", "read me first", "run me", "open me", "unlock")
INVISIBLE = {"‮", "‭", "​", "‎", "‏", "⁦", "⁧", "⁨"}

def ext(name):
    return os.path.splitext(name)[1].lower()

def name_flags(path):
    """Problems visible from the path alone (works before anything is downloaded)."""
    flags, lower = [], path.lower()
    parts = [p for p in path.replace("\\", "/").split("/") if p]
    e = ext(parts[-1]) if parts else ""
    if any(ch in path for ch in INVISIBLE):
        flags.append(("RED", "hidden direction/zero-width characters in the name (classic disguise)"))
    if any(ext(p) in DANGEROUS for p in parts[:-1]):
        flags.append(("RED", "inside an app/installer bundle"))
    if e in DANGEROUS:
        flags.append(("RED", f"{e} file: programs, installers and scripts don't belong in a media torrent"))
    stem = os.path.splitext(parts[-1])[0].lower() if parts else ""
    if e not in MEDIA and ext(stem) in MEDIA:
        flags.append(("RED", f"double extension: looks like {ext(stem)} but is really {e or 'no extension'}"))
    if e in ARCHIVES:
        flags.append(("AMBER", "archive: can hide anything; password-protected ones are a malware trick"))
    if any(b in lower for b in BAIT) and e not in SUBS:
        flags.append(("AMBER", "bait-style name (codec/setup/password/...)"))
    return flags

# ---------- plan: decide what to fetch before downloading ----------

def bdecode(data, i=0):
    c = data[i:i + 1]
    if c == b"i":
        j = data.index(b"e", i)
        return int(data[i + 1:j]), j + 1
    if c == b"l":
        out, i = [], i + 1
        while data[i:i + 1] != b"e":
            v, i = bdecode(data, i); out.append(v)
        return out, i + 1
    if c == b"d":
        out, i = {}, i + 1
        while data[i:i + 1] != b"e":
            k, i = bdecode(data, i); v, i = bdecode(data, i); out[k] = v
        return out, i + 1
    j = data.index(b":", i)
    n = int(data[i:j])
    return data[j + 1:j + 1 + n], j + 1 + n

def txt(b):
    return b.decode("utf-8", "replace") if isinstance(b, bytes) else str(b)

def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.0f} {u}" if u == "B" else f"{n:.1f} {u}"
        n /= 1024

def torrent_files(torrent):
    """(name, [(path, size), ...]) in aria2's --select-file order (1-based)."""
    info = bdecode(open(torrent, "rb").read())[0][b"info"]
    name = txt(info.get(b"name.utf-8", info[b"name"]))
    if b"files" in info:
        return name, [("/".join(txt(p) for p in f.get(b"path.utf-8", f[b"path"])), f[b"length"]) for f in info[b"files"]]
    return name, [(name, info[b"length"])]

def assess(path, size):
    """(kind, flags, blocked, preselect) for one file in a torrent."""
    e = ext(path)
    kind = "media" if e in MEDIA else "subtitle" if e in SUBS else "other"
    flags = name_flags(path)
    if kind == "media" and size < 1_000_000:
        flags.append(("AMBER", "tiny for a video; could be a fake"))
    blocked = any(lvl == "RED" for lvl, _ in flags)
    return kind, flags, blocked, kind != "other" and not blocked

def files_json(torrent):
    """For the app's file picker: every file with its kind, warnings, and whether it's blocked or ticked by default."""
    name, files = torrent_files(torrent)
    out = []
    for idx, (path, size) in enumerate(files, 1):
        kind, flags, blocked, pre = assess(path, size)
        out.append({"index": idx, "path": path, "size": size, "kind": kind,
                    "flags": [m for _, m in flags], "blocked": blocked, "preselect": pre})
    print(json.dumps({"name": name, "files": out}))

def plan(torrent, take_all):
    name, files = torrent_files(torrent)

    sel, red, sel_bytes = [], 0, 0
    out = sys.stderr
    print(f"\nTorrent: {name}   ({len(files)} files, {human(sum(s for _, s in files))})\n", file=out)
    for idx, (path, size) in enumerate(files, 1):
        kind, flags, is_red, wanted = assess(path, size)
        red += is_red
        take = take_all == "2" or (wanted and not is_red) or (take_all == "1" and not is_red)
        if take:
            sel.append(str(idx)); sel_bytes += size
        mark = "  get " if take else " skip "
        print(f"{mark} {human(size):>9}  {path}", file=out)
        for lvl, msg in flags:
            print(f"{'':16}{'!!' if lvl == 'RED' else ' !'} {msg}", file=out)
    print(file=out)
    if red and take_all == "2":
        print(f"--trust: downloading {red} flagged file(s) anyway. Only open them if you trust the source.", file=out)
    elif red:
        print(f"{red} dangerous file(s) found and will NOT be downloaded. Treat this torrent as suspicious.", file=out)
    if not sel:
        print("Nothing safe to download (no video/audio/subtitle files).", file=out)
        sys.exit(2)
    print(name)
    print(",".join(sel))
    print(sel_bytes)

# ---------- check: inspect what actually arrived ----------

def sniff(path):
    """What the bytes say the file is, ignoring its name."""
    with open(path, "rb") as f:
        h = f.read(16)
        try:
            f.seek(-512, 2); tail = f.read(512)
        except OSError:
            tail = b""
    if h[:4] in (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        return "exec", "Mac program (Mach-O)"
    if h[:2] == b"MZ":
        return "exec", "Windows program (PE)"
    if h[:4] == b"\x7fELF":
        return "exec", "Linux program (ELF)"
    if h[:2] == b"#!":
        return "exec", "script"
    if h[:4] == b"xar!":
        return "exec", "macOS installer package"
    if tail[:4] == b"koly":
        return "exec", "disk image (.dmg)"
    if h[:4] == b"PK\x03\x04" or h[:4] == b"Rar!" or h[:6] == b"7z\xbc\xaf\x27\x1c":
        return "archive", "archive"
    if h[:4] == b"\x1a\x45\xdf\xa3" or h[4:8] == b"ftyp" or h[:4] in (b"RIFF", b"OggS", b"fLaC", b"FLV\x01") \
            or h[:3] == b"ID3" or h[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf1") or h[:4] == b"\x30\x26\xb2\x75" \
            or h[:4] == b"\x00\x00\x01\xba" or h[:1] == b"\x47":
        return "media", "media"
    return "other", "unknown data"

def quarantine(path):
    stamp = f"0081;{int(time.time()):08x};Purrload;"
    subprocess.run(["xattr", "-w", "com.apple.quarantine", stamp, path], capture_output=True)

def check(root):
    files = [root] if os.path.isfile(root) else \
        [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if not f.endswith(".aria2")]
    report, red, amber = [], 0, 0
    for p in sorted(files):
        quarantine(p)
        rel = os.path.relpath(p, os.path.dirname(root))
        flags = name_flags(rel)
        e = ext(p)
        kind, what = sniff(p)
        if kind == "exec":
            flags.append(("RED", f"contents are a {what}"))
        elif e in MEDIA and kind != "media":
            flags.append(("RED", f"named like a video but contents are {what}"))
        elif e in SUBS:
            with open(p, "rb") as f:
                if b"\x00" in f.read(65536) and e not in (".sup", ".idx", ".sub"):
                    flags.append(("AMBER", "subtitle file contains binary data"))
        if os.access(p, os.X_OK) and kind != "exec":
            flags.append(("AMBER", "marked executable (shouldn't be for media)"))
        red += any(l == "RED" for l, _ in flags)
        amber += any(l == "AMBER" for l, _ in flags)
        tag = "BAD " if any(l == "RED" for l, _ in flags) else "warn" if flags else "ok  "
        report.append(f"{tag} {human(os.path.getsize(p)):>9}  {rel}")
        report += [f"{'':16}{'!!' if l == 'RED' else ' !'} {m}" for l, m in flags]

    verdict = ("DANGER: do not open the files marked BAD; delete them" if red else
               "CHECK: look at the warnings before opening" if amber else
               "CLEAN: only media and subtitles, all quarantined")
    text = "\n".join([f"Torrent check  {datetime.now():%Y-%m-%d %H:%M}  {root}", ""] + report +
                     ["", f"{len(files)} files, quarantine mark added to all.", verdict])
    print(text)
    os.makedirs(f"{BASE}/reports", exist_ok=True)
    with open(f"{BASE}/reports/{os.path.basename(root.rstrip('/'))[:80]}-{datetime.now():%Y%m%d-%H%M%S}.txt", "w") as f:
        f.write(text + "\n")
    subprocess.run(["osascript", "-e",
        f'display notification {json.dumps(verdict)} with title "Torrent check" sound name "Glass"'],
        capture_output=True)
    sys.exit(1 if red else 0)

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "plan":
        plan(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "0")
    elif len(sys.argv) == 3 and sys.argv[1] == "files":
        files_json(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        check(os.path.abspath(sys.argv[2]))
    else:
        sys.exit(__doc__)
