#!/usr/bin/env python3
"""Purrload engine: keeps downloads alive.

- Watches in-progress Safari downloads, and runs downloads dropped on the app (web links, magnets, .torrent files).
- Keeps the Mac awake (caffeinate) while any download is active.
- Tracks real on-disk progress, speed, ETA and signed-URL expiry.
- On failure, or a stall with Safari no longer writing, takes the partial file
  over and resumes it with curl range requests (same byte offset, same URL).
- Verifies finished files (exact size + Matroska/MP4 header) and notifies.
"""
import os, re, sys, time, json, signal, traceback, plistlib, subprocess, shutil, threading, uuid, tempfile, fcntl, termios, struct
from collections import deque
from datetime import datetime, timezone, timedelta
from urllib.parse import urlparse, parse_qs

HOME = os.path.expanduser("~")
PLIST = f"{HOME}/Library/Safari/Downloads.plist"
# Runtime data lives outside the code so logs, status and signed URLs never end up in git.
BASE = os.environ.get("PURRLOAD_HOME", f"{HOME}/Library/Application Support/Purrload")
os.makedirs(BASE, exist_ok=True)
LOG = f"{BASE}/engine.log"
STATUS = f"{BASE}/status.txt"
STATUS_JSON = f"{BASE}/status.json"
TICK = 2
STALL_SECS = 300        # no growth this long -> stalled
TAKEOVER_SECS = 300     # stalled AND Safari hasn't touched file this long -> curl takeover
EXPIRY_WARN = 1800      # warn when ETA lands within 30 min of link expiry
CURL_HANG_SECS = 60     # curl alive but no bytes this long -> restart it
PAUSE = f"{BASE}/PAUSE" # touch to pause all curl downloads, delete to resume
INBOX = f"{BASE}/inbox" # the app drops {"url": ...} files here to start a download
DOWNLOADS = os.environ.get("PURRLOAD_DOWNLOADS", f"{HOME}/Downloads")
SETTINGS = f"{BASE}/settings.json"   # written by the app: {"downloadFolder": "/path"}
JOBS_FILE = f"{BASE}/jobs.json"      # restored after a restart; private: has links
FINISHED = ("verified", "corrupt", "skipped", "danger")
INSPECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inspect.py")
ARIA2 = None if os.environ.get("PURRLOAD_NO_ARIA2") else (shutil.which("aria2c") or
        next((p for p in ("/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c") if os.path.exists(p)), None))
DIRECT_HANG_SECS = 90   # web download alive but no bytes this long -> restart it
TORRENT_HANG_SECS = 600 # torrents go quiet while finding peers; restarting throws the peers away, so wait much longer
# Speed: aria2's defaults are conservative. More peers, keep looking for peers until it's fast, local peer
# discovery, and a write cache (helps a lot on USB / exFAT drives). No extra trackers are added: that would
# leak private torrents to outside servers.
TORRENT_SPEED = ["--bt-max-peers=150", "--bt-request-peer-speed-limit=20M", "--bt-enable-lpd=true",
                 "--enable-peer-exchange=true", "--enable-dht=true", "--disk-cache=256M"]
VIDEO_EXTS = (".mkv", ".webm", ".mp4", ".m4v", ".mov")

def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")

EVENTS = deque(maxlen=30)    # notifications for the app
_event_ids = iter(range(1, 1 << 62))

def app_can_notify():
    try:
        allowed = open(f"{BASE}/notifications").read().strip() == "allowed"
    except OSError:
        allowed = False
    return allowed and subprocess.run(["pgrep", "-x", "Purrload"], capture_output=True).returncode == 0

def notify(title, msg, path=None):
    """Posted by the app when it can (its icon, click shows the file); otherwise AppleScript."""
    log(f"NOTIFY {title}: {msg}")
    EVENTS.append({"id": next(_event_ids), "time": time.time(), "title": title, "body": msg, "path": path})
    if not app_can_notify():
        subprocess.run(["osascript", "-e",
            f'display notification {json.dumps(msg)} with title {json.dumps(title)} sound name "Glass"'],
            capture_output=True)

def pretty(name):
    """'Show.Name.S01E02.Episode.Title.2160p.WEB-DL...' -> 'Show Name S01E02 Episode Title'"""
    stem = re.split(r"[. ](?:\d{3,4}p|WEB|BluRay|HDTV)\b", name, maxsplit=1)[0]
    return re.sub(r"[._]+", " ", stem).strip() or name

def short(name):
    m = re.search(r"S\d+E\d+", name)
    return m.group() if m else name[:40]

def url_expiry(url):
    q = parse_qs(urlparse(url).query)
    try:
        start = datetime.strptime(q["X-Amz-Date"][0], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        return start + timedelta(seconds=int(q["X-Amz-Expires"][0]))
    except (KeyError, ValueError):
        return None

def default_gateway():
    r = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True)
    m = re.search(r"gateway: (\S+)", r.stdout)
    return m.group(1) if m else None

def media_ok(path):
    with open(path, "rb") as f:
        head = f.read(12)
    return head[:4] == b"\x1a\x45\xdf\xa3" or head[4:8] == b"ftyp"

def fmt_bytes(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024 or u == "GB":
            return f"{n:.1f} {u}" if u != "B" else f"{n} B"
        n /= 1024

def fmt_dur(s):
    if s is None or s == float("inf"):
        return "?"
    s = int(s); h, s = divmod(s, 3600); m, s = divmod(s, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"

class Job:
    def __init__(self, entry):
        self.id = entry["DownloadEntryIdentifier"]
        self.partial = entry["DownloadEntryPath"]          # .../X.download/X
        self.bundle = os.path.dirname(self.partial)
        self.final = os.path.join(os.path.dirname(self.bundle), os.path.basename(self.partial))
        self.part = self.final + ".part"                   # used only after takeover
        self.url = entry["DownloadEntryURL"]
        self.total = entry.get("DownloadEntryProgressTotalToLoad", 0)
        self.expiry = url_expiry(self.url)
        self.name = short(os.path.basename(self.final))
        self.title = pretty(os.path.basename(self.final))
        self.hist = deque(maxlen=12)                        # (t, size) over ~2 min
        self.last_growth = time.time()
        self.state = "downloading"
        self.curl = None
        self.curl_attempts = 0
        self.warned = set()

    def current_file(self):
        if self.state == "takeover":
            return self.part
        return self.partial

    def size(self):
        p = self.current_file()
        return os.path.getsize(p) if os.path.exists(p) else None

    def speed(self):
        if len(self.hist) < 2:
            return 0
        (t0, s0), (t1, s1) = self.hist[0], self.hist[-1]
        return (s1 - s0) / (t1 - t0) if t1 > t0 else 0


def download_folder():
    try:
        chosen = json.load(open(SETTINGS)).get("downloadFolder")
    except (OSError, ValueError):
        chosen = None
    return os.path.expanduser(chosen) if chosen else DOWNLOADS

def folder_problem(path):
    """Why we can't save to `path`, or None. Never silently falls back to another folder."""
    parts = os.path.abspath(path).split("/")
    if len(parts) > 2 and parts[1] == "Volumes" and not os.path.ismount(f"/Volumes/{parts[2]}"):
        return f"\u201c{parts[2]}\u201d isn't connected: plug it in or choose another folder"
    try:
        os.makedirs(path, exist_ok=True)
    except OSError:
        return f"couldn't create the folder {os.path.basename(path.rstrip('/')) or path}"
    if not os.access(path, os.W_OK):
        return f"can't save to {os.path.basename(path.rstrip('/')) or path} (no permission)"
    return None

def filesystem(path):
    out = subprocess.run(["/sbin/mount"], capture_output=True, text=True).stdout
    best, kind = "", ""
    for line in out.splitlines():
        m = re.match(r"\S+ on (.+) \(([^,)]+)", line)
        if m and (path == m.group(1) or path.startswith(m.group(1).rstrip("/") + "/")) and len(m.group(1)) > len(best):
            best, kind = m.group(1), m.group(2)
    return kind

def piece_order(folder):
    """exFAT/FAT drives have no sparse files: writing a torrent piece far into a file makes the drive write zeros
    over the whole gap first, which stalls the download for minutes. Fetch pieces in order there, so files just grow."""
    return ["--stream-piece-selector=inorder"] if filesystem(folder) in ("exfat", "msdos", "vfat") else []

def quarantine(path):
    """Mark a file as downloaded so Gatekeeper checks it on first open (curl/aria2 don't do this)."""
    subprocess.run(["xattr", "-w", "com.apple.quarantine", f"0081;{int(time.time()):08x};Purrload;", path],
                   capture_output=True)

def probe(url):
    r = subprocess.run(["curl", "-sSIL", "--max-time", "20", url], capture_output=True, text=True, errors="replace")
    name, size = None, 0
    for line in r.stdout.splitlines():                     # last response wins (after redirects)
        k, _, v = line.partition(":")
        k = k.strip().lower()
        if k == "content-length" and v.strip().isdigit():
            size = int(v.strip())
        elif k == "content-disposition":
            m = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?', v, re.I)
            if m: name = m.group(1).strip()
    if not name:
        q = parse_qs(urlparse(url).query).get("response-content-disposition", [""])[0]
        m = re.search(r'filename="?([^";]+)"?', q)
        name = m.group(1) if m else os.path.basename(urlparse(url).path) or "download"
    return re.sub(r'[/\\:]', "_", name)[:200], size

def unique_path(folder, name):
    base, ext = os.path.splitext(name)
    path, n = os.path.join(folder, name), 1
    while os.path.exists(path) or os.path.exists(path + ".part"):
        path, n = os.path.join(folder, f"{base} ({n}){ext}"), n + 1
    return path

UNIT = {"B": 1, "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3, "TiB": 1024 ** 4}
READOUT = re.compile(r"\[#\w+ (?:SEED\([^)]*\) )?([\d.]+)(B|KiB|MiB|GiB|TiB)/([\d.]+)(B|KiB|MiB|GiB|TiB)")
READOUT_DL = re.compile(r"DL:([\d.]+)(B|KiB|MiB|GiB|TiB)")
READOUT_PEERS = re.compile(r"CN:(\d+)(?: SD:(\d+))?")     # connections, seeders

class Runner:
    """A download subprocess. For aria2 it parses the live readout ([#id 1.2GiB/2.5GiB(48%) ...]),
    because multi-connection and torrent downloads write out of order, so file size isn't progress.
    aria2 only prints that readout to a terminal (trimmed to its width), so it gets a 200-column pseudo-terminal."""
    def __init__(self, args, parse):
        self.done = self.total = self.speed = 0
        self.heard = 0.0                 # when aria2 last printed its progress
        self.conns = self.seeds = None
        self.parsed = parse
        if not parse:
            self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        self.master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 200, 0, 0))
        self.proc = subprocess.Popen(args + ["--enable-color=false"], stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
        os.close(slave)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        buf = b""
        while True:
            try:
                chunk = os.read(self.master, 4096)
            except OSError:          # EIO once aria2 exits and the terminal closes
                chunk = b""
            if not chunk:
                os.close(self.master)
                return
            buf += chunk
            *lines, buf = re.split(rb"[\r\n]", buf)
            for line in lines:
                text = line.decode("utf-8", "replace")
                m = READOUT.search(text)
                if m:
                    self.done = float(m.group(1)) * UNIT[m.group(2)]
                    self.total = float(m.group(3)) * UNIT[m.group(4)]
                    d = READOUT_DL.search(text)    # aria2's own speed: the sizes above are rounded to 0.1 GiB
                    self.speed = float(d.group(1)) * UNIT[d.group(2)] if d else 0
                    p = READOUT_PEERS.search(text)
                    self.conns = int(p.group(1)) if p else 0
                    self.seeds = int(p.group(2)) if p and p.group(2) else 0
                    self.heard = time.time()

    def alive(self):
        return self.proc.poll() is None

    def stop(self):
        if self.alive():
            self.proc.terminate()
            try: self.proc.wait(10)
            except subprocess.TimeoutExpired: self.proc.kill()

class DirectJob:
    def __init__(self, url, saved=None):
        self.id = str(uuid.uuid4())
        self.url = url
        self.torrent = url.startswith("magnet:") or urlparse(url).path.lower().endswith(".torrent")
        base = download_folder()
        self.folder = os.path.join(base, "Torrents") if self.torrent and os.path.abspath(base) == os.path.abspath(DOWNLOADS) else base
        self.name = self.title = "Magnet link" if url.startswith("magnet:") else (
            os.path.basename(urlparse(url).path) or "download")
        self.state = "starting"          # starting -> metadata (magnets) -> choosing (torrents) -> downloading -> verified | corrupt | danger
        self.files = None
        self.selection = None
        self.chosen = threading.Event()
        self.removed = False
        self.held = False                # paused on its own; PAUSE pauses everything
        self.top = None                  # a torrent's file or folder, once it's downloading
        self.existed = None              # it was there before we started: cancel must not delete it
        self.path = None
        self.message = ""
        self.total = 0
        self.run = None
        self.part = None
        self.hist = deque(maxlen=12)
        self.last_growth = time.time()
        self.final = None                # kept so a restart resumes the same .part
        self.seen = 0                    # aria2's last progress: while it's stopped, the file size isn't progress
        if saved:
            self.id = saved["id"]
            for k in ("folder", "name", "title", "total", "path", "message", "final", "held", "top", "existed", "seen"):
                if saved.get(k) is not None: setattr(self, k, saved[k])
            if saved.get("selection") is not None:
                self.selection = saved["selection"]
                self.chosen.set()
            if saved.get("state") in FINISHED:
                self.state = saved["state"]
                return
        threading.Thread(target=self.work, daemon=True).start()

    def saved(self):
        return {"id": self.id, "url": self.url, "folder": self.folder, "selection": self.selection, "state": self.state,
                "name": self.name, "title": self.title, "total": self.total, "path": self.path, "message": self.message,
                "final": self.final, "held": self.held, "top": self.top, "existed": self.existed, "seen": self.seen}

    def done_bytes(self):
        if self.state == "verified":
            return self.total
        if self.run and ARIA2 and (self.torrent or self.run.total) and self.run.done:
            self.seen = self.run.done
        if ARIA2 and self.seen:
            return self.seen
        return os.path.getsize(self.part) if self.part and os.path.exists(self.part) else 0

    def speed(self):
        if self.run and self.run.parsed and self.run.alive():
            # aria2 goes quiet when it's stuck (e.g. waiting on a slow drive): don't keep showing its last speed
            return self.run.speed if time.time() - self.run.heard < 3 else 0
        if len(self.hist) < 2:
            return 0
        (t0, s0), (t1, s1) = self.hist[0], self.hist[-1]
        return max(0, (s1 - s0) / (t1 - t0)) if t1 > t0 else 0

    def stall(self, gateway, now):
        """Why the speed is 0, for the app; None while moving or only briefly at 0."""
        if self.state != "downloading" or self.speed() > 0 or self.held or os.path.exists(PAUSE):
            self.zero_since = None
            return None
        self.zero_since = getattr(self, "zero_since", None) or now
        if now - self.zero_since < 10:
            return None
        hotspot = (gateway or "").startswith("172.20.10.")      # the subnet an iPhone hotspot hands out
        if gateway is None:
            return "No internet · carries on when it's back"
        r = self.run
        if not (r and r.alive()):       # between restarts its peer counts are stale
            return None
        if r.parsed and now - r.heard >= 3:
            slow = filesystem(self.folder) in ("exfat", "msdos", "vfat")
            return "Waiting on the drive" + (" · slow USB disk, normal" if slow else " · it's busy writing")
        if self.torrent and r and r.conns == 0:
            return "Looking for peers" + (" · hotspots block incoming peers" if hotspot else " · nobody's online right now")
        if self.torrent and r and r.conns:
            return f"{r.conns} peers, none sending" + (" · hotspot may be throttled" if hotspot else " · usually comes back")
        if not self.torrent:
            return "The server stopped sending · Purrload keeps retrying"
        return None

    def set_name(self, name):
        self.title = pretty(name)
        self.name = short(name) if re.search(r"S\d+E\d+", name) else self.title[:40]

    def cancel(self):
        """Stop it and delete what it downloaded so far. Runs on its own thread: aria2 can take a while to exit."""
        self.removed = True
        self.chosen.set()
        while True:                      # the worker may have started a new run just before it saw `removed`
            r = self.run
            if r:
                r.stop()
                try: r.proc.wait(60)     # stuck in disk wait: deleting under it would just be rewritten
                except subprocess.TimeoutExpired: pass
                if r.alive():
                    return log(f"{self.name}: aria2 didn't exit; left its files alone")
            time.sleep(1)
            if self.run is r:
                break
        doomed = []
        if not self.torrent and self.part:
            doomed = [self.part, self.part + ".aria2"]
        elif self.torrent and self.top:
            doomed = [self.top + ".aria2"] + ([] if self.existed else [self.top])
        for p in doomed:
            try:
                shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)
            except FileNotFoundError:
                pass
            except OSError as e:
                log(f"{self.name}: couldn't delete {os.path.basename(p)} ({e})")
        log(f"{self.name}: cancelled" + (", kept the folder that was already there" if self.torrent and self.existed else ""))

    def work(self):
        try:
            if not self.torrent and (problem := folder_problem(self.folder)):   # torrents check once a folder is chosen
                return self.fail(problem)
            self.work_torrent() if self.torrent else self.work_http()
        except Exception as e:
            self.fail(f"error: {e}")

    def fail(self, msg, state="corrupt"):
        if self.removed:                 # cancelled: its download stopping isn't a failure
            return
        self.state, self.message = state, msg
        log(f"{self.name}: {msg}")
        notify("Purrload", f"{self.name}: {msg}")

    def waiting(self):
        return self.held or os.path.exists(PAUSE)

    def attempts(self, make_args, parse, complete, tries=10):
        tried = 0
        while tried < tries:
            while self.waiting() and not self.removed:
                time.sleep(1)
            if self.removed:
                return False
            self.run = Runner(make_args(), parse)
            self.run.proc.wait()
            if self.removed:
                return False
            if complete():
                return True
            if not self.waiting():       # stopped for a pause: not a failed attempt
                tried += 1
                time.sleep(3)
        return False

    def work_http(self):
        name, self.total = probe(self.url)
        self.set_name(name)
        final = self.final or unique_path(self.folder, name)   # after a restart: the same file, so it resumes
        self.final = final
        self.part = final + ".part"
        self.state = "downloading"
        log(f"{self.name}: downloading to {self.folder} ({fmt_bytes(self.total) if self.total else 'size unknown'})")
        if ARIA2:
            make = lambda: [ARIA2, self.url, "-d", self.folder, "-o", os.path.basename(self.part), "-c",
                            "-x16", "-s16", "-k1M", "--disk-cache=32M", "--file-allocation=none", "--auto-file-renaming=false",
                            "--allow-overwrite=true", "--console-log-level=error", "--summary-interval=0",
                            "--max-tries=5", "--retry-wait=3"]
        else:
            make = lambda: ["curl", "-sS", "-L", "-C", "-", "--retry", "5", "--retry-all-errors", "-o", self.part, self.url]
        def complete():
            if not os.path.exists(self.part) or os.path.exists(self.part + ".aria2"):
                return False
            return self.run.proc.returncode == 0 and (not self.total or os.path.getsize(self.part) == self.total)
        if not self.attempts(make, bool(ARIA2), complete):
            return self.fail("download kept failing; drop the link again to retry")
        if self.removed:
            return
        size = os.path.getsize(self.part)
        if final.lower().endswith(VIDEO_EXTS) and not media_ok(self.part):
            return self.fail("finished, but it isn't a valid video file")
        quarantine(self.part)
        os.rename(self.part, final)
        self.part, self.total, self.state = None, size, "verified"
        self.message, self.path = os.path.basename(final), final
        notify("Download complete", f"{self.name} ({fmt_bytes(size)})", final)

    def work_torrent(self):
        if not ARIA2:
            return self.fail("torrents need aria2: brew install aria2")
        work = tempfile.mkdtemp(prefix="purrload-")
        try:
            self.torrent_in(work)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def torrent_in(self, work):
        tor = self.url
        if re.match(r"https?://", self.url):
            tor = os.path.join(work, "download.torrent")
            r = subprocess.run(["curl", "-sSL", "--max-time", "60", "--max-filesize", "50000000", "-o", tor, self.url],
                               capture_output=True, text=True)
            if r.returncode != 0 or not os.path.exists(tor):
                return self.fail(f"couldn't fetch the .torrent file ({(r.stderr.strip() or 'no response')[:80]})")
            with open(tor, "rb") as f:
                if f.read(1) != b"d":                # torrents are bencoded dictionaries; an HTML error page isn't
                    return self.fail("the link didn't return a .torrent file (the site may need you to log in)")
        elif self.url.startswith("magnet:"):
            self.state = "metadata"
            self.run = Runner([ARIA2, "-d", work, "--bt-metadata-only=true", "--bt-save-metadata=true",
                               "--bt-stop-timeout=120", "--console-log-level=error", "--summary-interval=0", self.url], False)
            self.run.proc.wait()
            found = [f for f in os.listdir(work) if f.endswith(".torrent")]
            if not found:
                return self.fail("no peers sent the file list; try again later")
            tor = os.path.join(work, found[0])
        listing = subprocess.run([sys.executable, "-I", INSPECT, "files", tor], capture_output=True, text=True)
        if listing.returncode != 0:                  # a real error: say so, don't call it "no media"
            err = (listing.stderr.strip().splitlines() or ["unknown error"])[-1]
            log(f"{self.name}: torrent listing failed: {err[:200]}")
            return self.fail("couldn't read it: it may be damaged, or not a .torrent file")
        info = json.loads(listing.stdout)
        name, self.files = info["name"], info["files"]
        self.set_name(name)
        if all(f["blocked"] for f in self.files):
            return self.fail("every file in it was flagged by the safety check", "danger")
        if not self.chosen.is_set():
            self.state = "choosing"
            log(f"{self.name}: {len(self.files)} files, waiting for the user to choose")
        self.chosen.wait()
        if self.removed:
            return
        allowed = {f["index"] for f in self.files if not f["blocked"]}
        picked = sorted(i for i in (self.selection or []) if i in allowed)   # never download a blocked file
        if not picked:
            return self.fail("nothing was selected")
        if problem := folder_problem(self.folder):
            return self.fail(problem)
        sel = ",".join(map(str, picked))
        self.total = sum(f["size"] for f in self.files if f["index"] in picked)
        self.files = None
        if self.existed is None:
            self.top = os.path.join(self.folder, name)
            self.existed = os.path.exists(self.top)
        self.state = "downloading"
        log(f"{self.name}: torrent, fetching {len(picked)} chosen file(s)")
        make = lambda: [ARIA2, "-d", self.folder, "-T", tor, f"--select-file={sel}", "--bt-remove-unselected-file=true",
                        "-c", "--file-allocation=none", "--seed-time=0", "--max-tries=0", "--retry-wait=5",
                        "--console-log-level=error", "--summary-interval=0", *TORRENT_SPEED, *piece_order(self.folder)]
        if not self.attempts(make, True, lambda: self.run.proc.returncode == 0):
            return self.fail("torrent download kept failing")
        if self.removed:
            return
        check = subprocess.run([sys.executable, "-I", INSPECT, "check", os.path.join(self.folder, name)],
                               capture_output=True, text=True, env={**os.environ, "PURRLOAD_QUIET": "1"})
        if check.returncode == 1:
            return self.fail("the safety check flagged files in it: don't open them", "danger")
        self.state, self.message, self.path = "verified", name, os.path.join(self.folder, name)
        notify("Download complete", f"{self.name}: checked, nothing suspicious inside", self.path)

class Engine:
    def __init__(self):
        self.jobs = {}
        self.caff = None
        self.volume_warned = set()
        self.removed = set()
        self.gateway = default_gateway()
        self.paused = os.path.exists(PAUSE)  # start in the current state, so a restart doesn't announce "paused" again
        self.safari = "ok"                   # "blocked": no Full Disk Access, so Safari downloads aren't watched

    def read_plist(self):
        try:
            with open(PLIST, "rb") as f:
                entries = plistlib.load(f).get("DownloadHistory", [])
        except PermissionError:
            if self.safari != "blocked":
                log("can't read Safari's download list: Purrload needs Full Disk Access to watch Safari downloads")
            self.safari = "blocked"
            return None
        except FileNotFoundError:
            return None         # Safari hasn't downloaded anything yet
        except Exception as e:  # Safari may be mid-write
            log(f"plist read failed ({e}); retrying next tick")
            return None
        if self.safari == "blocked":
            log("can read Safari's download list again")
        self.safari = "ok"
        return entries

    def sync_entries(self, entries):
        for e in entries:
            path = e.get("DownloadEntryPath", "")
            jid = e.get("DownloadEntryIdentifier")
            if not jid or ".download/" not in path:
                continue
            final = os.path.join(os.path.dirname(os.path.dirname(path)), os.path.basename(path))
            orphan = os.path.exists(final + ".part")      # failed in Safari, taken over earlier
            if jid not in self.jobs and jid not in self.removed and ("DownloadEntryDateFinishedKey" not in e or orphan):
                j = Job(e)
                self.jobs[jid] = j
                exp = j.expiry.astimezone().strftime("%H:%M") if j.expiry else "unknown"
                log(f"tracking {j.name}  total {fmt_bytes(j.total)}  link expires {exp}")
            j = self.jobs.get(jid)
            if j and j.state == "downloading" and "DownloadEntryErrorCodeDictionaryKey" in e:
                code = e["DownloadEntryErrorCodeDictionaryKey"]
                log(f"{j.name}: Safari reports error {code}")
                j.state = "failed"

    def check_volume(self, j):
        vol = "/".join(j.final.split("/")[:3]) if j.final.startswith("/Volumes/") else "/"
        if not os.path.ismount(vol):
            if vol not in self.volume_warned:
                notify("Purrload", f"{vol} is disconnected; downloads paused until it's back")
                self.volume_warned.add(vol)
            return False
        if vol in self.volume_warned:
            log(f"{vol} reconnected")
            self.volume_warned.discard(vol)
        return True

    def takeover(self, j, reason):
        if j.expiry and datetime.now(timezone.utc) >= j.expiry:
            if "expired" not in j.warned:
                notify("Purrload", f"{j.name}: link expired, get a fresh link from the site")
                j.warned.add("expired")
            j.state = "expired"
            return
        if j.state != "takeover" and not os.path.exists(j.partial) and os.path.exists(j.part):
            j.state = "takeover"            # adopted from a previous engine run
            log(f"{j.name}: adopting existing {fmt_bytes(j.size())} .part file")
        if j.state != "takeover":
            if not os.path.exists(j.partial):
                log(f"{j.name}: no partial file to take over")
                return
            os.rename(j.partial, j.part)    # same volume: instant; Safari can no longer clobber it
            j.state = "takeover"
            notify("Purrload", f"{j.name}: {reason}; resuming with curl from {fmt_bytes(j.size())}")
        self.start_curl(j)

    def stop_curl(self, j, why):
        if j.curl and j.curl.poll() is None:
            log(f"{j.name}: restarting curl ({why})")
            j.curl.terminate()
            try: j.curl.wait(10)
            except subprocess.TimeoutExpired: j.curl.kill()
        j.curl = None

    def start_curl(self, j):
        j.last_growth = time.time()
        j.curl_attempts += 1
        log(f"{j.name}: curl attempt {j.curl_attempts} from byte {j.size()}")
        j.curl = subprocess.Popen(
            ["curl", "-sS", "-L", "-C", "-", "--retry", "30", "--retry-all-errors",
             "--retry-delay", "5", "--speed-limit", "10240", "--speed-time", "120",
             "-o", j.part, j.url],
            stdout=subprocess.DEVNULL, stderr=open(f"{BASE}/curl-{j.name}.err", "a"))

    def finish(self, j, path):
        size = os.path.getsize(path)
        if j.total and size != j.total:
            notify("Purrload", f"{j.name}: size mismatch {size} vs {j.total}, needs re-download")
            j.state = "corrupt"
            return
        if path.lower().endswith(VIDEO_EXTS) and not media_ok(path):
            notify("Purrload", f"{j.name}: finished but header isn't a valid video container")
            j.state = "corrupt"
            return
        j.state = "verified"
        notify("Download complete", f"{j.name} verified ({fmt_bytes(size)})", path)

    def step(self, j, now):
        if j.state in ("verified", "corrupt", "expired"):
            return
        if not self.check_volume(j):
            return
        if j.state in ("downloading", "failed") and not os.path.exists(j.partial) and os.path.exists(j.part):
            self.takeover(j, "adopting")

        if j.state == "takeover":
            if self.paused:
                self.stop_curl(j, "paused")
                return
            if j.curl and j.curl.poll() is None:
                if time.time() - j.last_growth > CURL_HANG_SECS:
                    self.stop_curl(j, f"no bytes for {CURL_HANG_SECS}s")
                    j.curl_attempts -= 1     # a hang isn't a real failure
                    self.start_curl(j)
            elif j.size() == j.total:
                os.rename(j.part, j.final)
                shutil.rmtree(j.bundle, ignore_errors=True)
                self.finish(j, j.final)
                return
            elif j.curl is None and j.curl_attempts > 0 and j.size() is not None:
                self.start_curl(j)
            elif j.curl_attempts < 10:
                self.takeover(j, "curl exited early")
            else:
                notify("Purrload", f"{j.name}: curl gave up after 10 attempts")
                j.state = "corrupt"
                return

        if j.state == "downloading" and not os.path.exists(j.partial) and os.path.exists(j.final):
            self.finish(j, j.final)
            return

        size = j.size()
        if size is None:
            return
        if not j.hist or size > j.hist[-1][1]:
            j.last_growth = now
        j.hist.append((now, size))

        if j.state == "failed":
            self.takeover(j, "Safari failed")
            return
        idle = now - j.last_growth
        if j.state == "downloading" and idle > STALL_SECS:
            mtime_idle = now - os.path.getmtime(j.partial)
            if "stall" not in j.warned:
                notify("Purrload", f"{j.name}: no progress for {fmt_dur(idle)}")
                j.warned.add("stall")
            if mtime_idle > TAKEOVER_SECS:
                self.takeover(j, "stalled")
                return
        elif idle < STALL_SECS:
            j.warned.discard("stall")

        sp = j.speed()
        eta = (j.total - size) / sp if sp > 0 else float("inf")
        if j.expiry and sp > 0 and "expiry" not in j.warned:
            left = (j.expiry - datetime.now(timezone.utc)).total_seconds()
            if eta > left - EXPIRY_WARN:
                notify("Purrload", f"{j.name}: ETA {fmt_dur(eta)} but link expires in {fmt_dur(left)}")
                j.warned.add("expiry")

    def active(self):
        return [j for j in self.jobs.values() if j.state in ("downloading", "failed", "takeover", "starting", "metadata")
                and not getattr(j, "held", False)]

    def keep_awake(self):
        if self.active() and (self.caff is None or self.caff.poll() is not None):
            self.caff = subprocess.Popen(["caffeinate", "-i", "-m", "-s", "-w", str(os.getpid())])
            log("caffeinate on: Mac will stay awake while downloads run")
        elif not self.active() and self.caff and self.caff.poll() is None:
            self.caff.terminate(); self.caff = None
            log("caffeinate off: nothing downloading")

    def write_status(self):
        rows = [f"Purrload  ·  {datetime.now():%H:%M:%S}", ""]
        tot_sp, items = 0, []
        for j in self.jobs.values():
            if isinstance(j, DirectJob):
                size, sp = j.done_bytes(), j.speed() if j.state == "downloading" and not j.held else 0
                tot_sp += sp
                items.append({"id": j.id, "name": j.name, "title": j.title, "state": j.state, "done": size,
                              "total": j.total, "speed": sp, "eta": (j.total - size) / sp if sp > 0 and j.total else None,
                              "folder": j.folder, "message": j.message, "files": j.files if j.state == "choosing" else None,
                              "canRetry": j.state in ("corrupt", "skipped"), "path": j.path, "held": j.held,
                              "canPause": j.state == "downloading", "canCancel": j.state in ("starting", "metadata", "downloading"),
                              "stall": j.stall(self.gateway, time.time())})
                rows.append(f"{j.name[:8]:8} {j.state:11} {100 * size / j.total if j.total else 0:5.1f}%  "
                            f"{fmt_bytes(size):>9} / {fmt_bytes(j.total):<9} {sp / 1048576:5.2f} MB/s")
                continue
            size = j.size() or (os.path.getsize(j.final) if os.path.exists(j.final) else 0)
            sp = j.speed() if j.state in ("downloading", "takeover") else 0
            tot_sp += sp
            pct = 100 * size / j.total if j.total else 0
            eta = (j.total - size) / sp if sp > 0 else None
            exp = j.expiry.astimezone().strftime("%H:%M") if j.expiry else "-"
            items.append({"id": j.id, "name": j.name, "title": j.title, "state": j.state,
                          "done": size, "total": j.total, "speed": sp, "eta": eta,
                          "folder": os.path.dirname(j.final), "path": j.final if j.state == "verified" else None})
            rows.append(f"{j.name:8} {j.state:11} {pct:5.1f}%  {fmt_bytes(size):>9} / {fmt_bytes(j.total):<9}"
                        f" {sp/1048576:5.2f} MB/s  ETA {fmt_dur(eta):>7}  link exp {exp}")
        rows += ["", f"total {tot_sp/1048576:.2f} MB/s"]
        with open(STATUS, "w") as f:
            f.write("\n".join(rows) + "\n")
        tmp = STATUS_JSON + ".tmp"   # write-then-rename so the bar never reads half a file
        with open(tmp, "w") as f:
            json.dump({"updated": time.time(), "speed": tot_sp, "paused": self.paused,
                       "online": self.gateway is not None, "events": list(EVENTS), "safari": self.safari,
                       "jobs": items}, f)
        os.replace(tmp, STATUS_JSON)

    def take_inbox(self):
        try:
            names = sorted(os.listdir(INBOX))
        except FileNotFoundError:
            return False
        for n in names:
            p = os.path.join(INBOX, n)
            try:
                msg = json.load(open(p))
            except Exception:
                msg = {}
            os.remove(p)
            if "select" in msg:
                j = self.jobs.get(msg["select"])
                if isinstance(j, DirectJob) and j.state == "choosing":
                    j.selection = [int(i) for i in msg.get("files", [])]
                    if msg.get("folder"):
                        j.folder = os.path.expanduser(str(msg["folder"]))
                    j.chosen.set()
            elif "retry" in msg:
                j = self.jobs.get(msg["retry"])
                if isinstance(j, DirectJob) and j.state in ("corrupt", "skipped"):
                    del self.jobs[j.id]
                    n = DirectJob(j.url)
                    self.jobs[n.id] = n
                    log(f"{j.name}: retrying")
            elif "pause" in msg or "resume" in msg:
                j = self.jobs.get(msg.get("pause") or msg.get("resume"))
                if isinstance(j, DirectJob) and j.held != ("pause" in msg):
                    j.held = "pause" in msg
                    log(f"{j.name}: {'paused' if j.held else 'resumed'}")
            elif "cancel" in msg:
                j = self.jobs.get(msg["cancel"])
                if isinstance(j, DirectJob) and j.state in ("starting", "metadata", "downloading", "choosing"):
                    self.removed.add(j.id)
                    del self.jobs[j.id]
                    threading.Thread(target=j.cancel, daemon=True).start()
            elif "remove" in msg:
                j = self.jobs.get(msg["remove"])
                if j and j.state not in ("downloading", "takeover", "failed", "metadata", "starting"):
                    if isinstance(j, DirectJob):
                        j.removed = True
                        j.chosen.set()
                    self.removed.add(j.id)
                    del self.jobs[j.id]
            elif "url" in msg:
                url = str(msg["url"]).strip()
                if re.match(r"(https?://|magnet:\?)", url) or (url.lower().endswith(".torrent") and os.path.exists(url)):
                    j = DirectJob(url)
                    self.jobs[j.id] = j
                    log(f"added a {'torrent' if j.torrent else 'web'} download from the app")
                else:
                    log("ignored an inbox item that isn't a web link, magnet or .torrent file")
        return bool(names)

    def step_direct(self, j, now):
        if j.state not in ("downloading", "metadata"):
            return
        size = j.done_bytes()
        if not j.hist or size > j.hist[-1][1] or (j.run and j.run.parsed and j.run.speed > 0):
            j.last_growth = now
        j.hist.append((now, size))
        if self.paused or j.held:
            j.last_growth = now       # time spent paused isn't a hang
            if j.run:
                j.run.stop()          # the worker waits for the pause to end, then resumes
        elif j.state == "downloading" and j.run and j.run.alive() and \
                now - j.last_growth > (TORRENT_HANG_SECS if j.torrent else DIRECT_HANG_SECS):
            log(f"{j.name}: no bytes for {TORRENT_HANG_SECS if j.torrent else DIRECT_HANG_SECS}s, restarting")
            j.last_growth = now
            j.run.stop()

    def save_jobs(self):
        items = [j.saved() for j in self.jobs.values() if isinstance(j, DirectJob)]
        tmp = JOBS_FILE + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)   # owner-only: it has the links
        with os.fdopen(fd, "w") as f:
            json.dump(items, f)
        os.replace(tmp, JOBS_FILE)

    def restore_jobs(self):
        try:
            items = json.load(open(JOBS_FILE))
        except (OSError, ValueError):
            return
        for s in items:
            j = DirectJob(s["url"], saved=s)
            self.jobs[j.id] = j
            if j.state not in FINISHED:
                log(f"{j.name}: picked up again after a restart")

    def shutdown(self, signum, frame):
        """SIGTERM: save the downloads and stop aria2 so nothing is left writing the files."""
        log("asked to stop: saving downloads and stopping aria2")
        try: self.save_jobs()
        except Exception: pass
        runs = [j.run for j in list(self.jobs.values()) if isinstance(j, DirectJob) and j.run and j.run.alive()]
        for r in runs:
            r.proc.terminate()
        deadline = time.time() + 15
        for r in runs:
            try: r.proc.wait(max(0.1, deadline - time.time()))
            except subprocess.TimeoutExpired: r.proc.kill()
        os._exit(0)      # not sys.exit: the download workers are threads and would restart what we just stopped

    def tick(self):
        self.take_inbox()
        entries = self.read_plist()
        if entries is not None:
            self.sync_entries(entries)
        now = time.time()
        paused = os.path.exists(PAUSE)
        if paused != self.paused:
            self.paused = paused
            notify("Purrload", "paused" if paused else "resumed")
        gw = default_gateway()
        if gw != self.gateway:
            log(f"network changed: gateway {self.gateway} -> {gw}")
            self.gateway = gw
            for j in self.jobs.values():
                if isinstance(j, DirectJob):
                    if j.run: j.run.stop()      # its worker restarts it on the new network
                elif j.state == "takeover":
                    self.stop_curl(j, "network changed")
        for j in list(self.jobs.values()):
            try:
                self.step_direct(j, now) if isinstance(j, DirectJob) else self.step(j, now)
            except Exception as e:
                log(f"{j.name}: error {e!r}")
        self.keep_awake()
        self.write_status()
        self.save_jobs()

    def run(self):
        log(f"engine started (pid {os.getpid()}, aria2 {'found' if ARIA2 else 'not found'})")
        os.makedirs(INBOX, exist_ok=True)
        self.restore_jobs()
        while True:
            try:
                self.tick()
            except Exception:       # one bad tick mustn't end the engine
                log("tick failed, will try again:\n" + traceback.format_exc().rstrip())
            for _ in range(TICK if self.active() else 10):
                time.sleep(1)
                if os.listdir(INBOX):
                    break

if __name__ == "__main__":
    os.makedirs(BASE, exist_ok=True)
    lock = open(f"{BASE}/engine.lock", "w")      # held for the engine's life
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Purrload engine is already running.")
        sys.exit(0)
    # a previous engine's curls may still be writing our .part files: stop them first
    subprocess.run(["pkill", "-f", "curl -sS -L -C - --retry 30"], capture_output=True)
    # and aria2 orphaned by an engine that was killed hard (only ours pass --enable-color=false)
    def orphan_aria2():
        ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        return [int(pid) for pid, ppid, cmd in (l.split(None, 2) for l in ps.splitlines() if l.count(" ") >= 2)
                if ppid == "1" and "aria2c" in cmd and "--enable-color=false" in cmd]
    for pid in orphan_aria2():
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
    for _ in range(60):
        if not orphan_aria2():
            break
        time.sleep(1)
    engine = Engine()
    signal.signal(signal.SIGTERM, engine.shutdown)
    engine.run()
