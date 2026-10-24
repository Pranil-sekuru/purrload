#!/usr/bin/env python3
"""Purrload engine: keeps downloads alive.

- Watches in-progress Safari downloads, and runs downloads dropped on the app (web links, magnets, .torrent files).
- Keeps the Mac awake (caffeinate) while any download is active.
- Tracks real on-disk progress, speed, ETA and signed-URL expiry.
- On failure, or a stall with Safari no longer writing, takes the partial file
  over and resumes it with curl range requests (same byte offset, same URL).
- Verifies finished files (exact size + Matroska/MP4 header) and notifies.
"""
import os, re, sys, time, json, plistlib, subprocess, shutil, threading, uuid, tempfile, fcntl, termios, struct
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
STATUS_JSON = f"{BASE}/status.json"  # read by the Purrload app
TICK = 2
STALL_SECS = 300        # no growth this long -> stalled
TAKEOVER_SECS = 300     # stalled AND Safari hasn't touched file this long -> curl takeover
EXPIRY_WARN = 1800      # warn when ETA lands within 30 min of link expiry
CURL_HANG_SECS = 60     # curl alive but no bytes this long -> restart it
PAUSE = f"{BASE}/PAUSE" # touch to pause all curl downloads, delete to resume
INBOX = f"{BASE}/inbox" # the app drops {"url": ...} files here to start a download
DOWNLOADS = os.environ.get("PURRLOAD_DOWNLOADS", f"{HOME}/Downloads")
SETTINGS = f"{BASE}/settings.json"   # written by the app: {"downloadFolder": "/path"}
INSPECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inspect.py")
ARIA2 = None if os.environ.get("PURRLOAD_NO_ARIA2") else (shutil.which("aria2c") or
        next((p for p in ("/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c") if os.path.exists(p)), None))
DIRECT_HANG_SECS = 90   # dropped download alive but no bytes this long -> restart it
VIDEO_EXTS = (".mkv", ".webm", ".mp4", ".m4v", ".mov")

def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")

EVENTS = deque(maxlen=30)    # notifications for the app to show, published in status.json
_event_ids = iter(range(1, 1 << 62))

def app_can_notify():
    """True if the Purrload app is running and macOS lets it show notifications (it writes that answer for us)."""
    try:
        allowed = open(f"{BASE}/notifications").read().strip() == "allowed"
    except OSError:
        allowed = False
    return allowed and subprocess.run(["pgrep", "-x", "Purrload"], capture_output=True).returncode == 0

def notify(title, msg, path=None):
    """Show a notification. The Purrload app posts it (with its own name and icon, and a click on a finished
    download shows it in Finder); if the app isn't running or isn't allowed to notify, fall back to AppleScript."""
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
    """Where new downloads go: the folder chosen in the app, read fresh for every download."""
    try:
        chosen = json.load(open(SETTINGS)).get("downloadFolder")
    except (OSError, ValueError):
        chosen = None
    return os.path.expanduser(chosen) if chosen else DOWNLOADS

def folder_problem(path):
    """Why we can't save to `path` (in plain words), or None if it's fine. Never silently saves somewhere else."""
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

def quarantine(path):
    """Mark a file as downloaded so Gatekeeper checks it on first open (curl/aria2 don't do this)."""
    subprocess.run(["xattr", "-w", "com.apple.quarantine", f"0081;{int(time.time()):08x};Purrload;", path],
                   capture_output=True)

def probe(url):
    """(filename, size) for a web link, from its headers, falling back to the URL itself."""
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

class Runner:
    """A download subprocess. For aria2 it parses the live readout ([#id 1.2GiB/2.5GiB(48%) ...]),
    because multi-connection and torrent downloads write out of order, so file size isn't progress.
    aria2 only prints that readout to a terminal (trimmed to its width), so it gets a 200-column pseudo-terminal."""
    def __init__(self, args, parse):
        self.done = self.total = self.speed = 0
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

    def alive(self):
        return self.proc.poll() is None

    def stop(self):
        if self.alive():
            self.proc.terminate()
            try: self.proc.wait(10)
            except subprocess.TimeoutExpired: self.proc.kill()

class DirectJob:
    """A download Purrload runs itself (dropped/accepted in the app). One worker thread per job."""
    def __init__(self, url):
        self.id = str(uuid.uuid4())
        self.url = url
        # a magnet, a .torrent file on disk, or a web link to a .torrent file (query strings allowed)
        self.torrent = url.startswith("magnet:") or urlparse(url).path.lower().endswith(".torrent")
        base = download_folder()
        self.folder = os.path.join(base, "Torrents") if self.torrent else base
        self.name = self.title = "Magnet link" if url.startswith("magnet:") else (
            os.path.basename(urlparse(url).path) or "download")
        self.state = "starting"          # starting -> metadata (magnets) -> choosing (torrents) -> downloading -> verified | corrupt | danger
        self.files = None                # torrents: the file list shown in the app's picker
        self.selection = None            # torrents: file indices the user picked
        self.chosen = threading.Event()  # set when the user picks files, or removes the job
        self.removed = False
        self.path = None                 # finished: what to show in Finder
        self.message = ""
        self.total = 0
        self.run = None                  # current Runner
        self.part = None                 # http: the .part file being written
        self.hist = deque(maxlen=12)
        self.last_growth = time.time()
        threading.Thread(target=self.work, daemon=True).start()

    # ----- progress, read by the main loop -----
    def done_bytes(self):
        if self.state == "verified":
            return self.total
        if self.run and ARIA2 and (self.torrent or self.run.total):
            return self.run.done
        return os.path.getsize(self.part) if self.part and os.path.exists(self.part) else 0

    def speed(self):
        if self.run and self.run.parsed and self.run.alive():
            return self.run.speed
        if len(self.hist) < 2:
            return 0
        (t0, s0), (t1, s1) = self.hist[0], self.hist[-1]
        return max(0, (s1 - s0) / (t1 - t0)) if t1 > t0 else 0

    def set_name(self, name):
        self.title = pretty(name)
        self.name = short(name) if re.search(r"S\d+E\d+", name) else self.title[:40]

    # ----- worker thread -----
    def work(self):
        try:
            if not self.torrent and (problem := folder_problem(self.folder)):   # torrents check once a folder is chosen
                return self.fail(problem)
            self.work_torrent() if self.torrent else self.work_http()
        except Exception as e:
            self.fail(f"error: {e}")

    def fail(self, msg, state="corrupt"):
        self.state, self.message = state, msg
        log(f"{self.name}: {msg}")
        notify("Purrload", f"{self.name}: {msg}")

    def attempts(self, make_args, parse, complete, tries=10):
        """Run the download command, restarting it (it resumes) until complete() or out of tries."""
        for _ in range(tries):
            while os.path.exists(PAUSE):
                time.sleep(2)
            self.run = Runner(make_args(), parse)
            self.run.proc.wait()
            if complete():
                return True
            time.sleep(3)
        return False

    def work_http(self):
        name, self.total = probe(self.url)
        self.set_name(name)
        final = unique_path(self.folder, name)
        self.part = final + ".part"
        self.state = "downloading"
        log(f"{self.name}: downloading to {self.folder} ({fmt_bytes(self.total) if self.total else 'size unknown'})")
        if ARIA2:
            make = lambda: [ARIA2, self.url, "-d", self.folder, "-o", os.path.basename(self.part), "-c",
                            "-x8", "-s8", "-k1M", "--file-allocation=none", "--auto-file-renaming=false",
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
            shutil.rmtree(work, ignore_errors=True)   # the fetched .torrent / magnet metadata

    def torrent_in(self, work):
        tor = self.url
        if re.match(r"https?://", self.url):         # a web link to a .torrent file: fetch it first
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
        self.set_name(name)                          # the real name, as soon as we know it
        if all(f["blocked"] for f in self.files):
            return self.fail("every file in it was flagged by the safety check", "danger")
        self.state = "choosing"                      # wait for the user to pick files in the app
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
        self.state = "downloading"
        log(f"{self.name}: torrent, fetching {len(picked)} chosen file(s)")
        make = lambda: [ARIA2, "-d", self.folder, "-T", tor, f"--select-file={sel}", "--bt-remove-unselected-file=true",
                        "-c", "--file-allocation=none", "--seed-time=0", "--max-tries=0", "--retry-wait=5",
                        "--console-log-level=error", "--summary-interval=0"]
        if not self.attempts(make, True, lambda: self.run.proc.returncode == 0):
            return self.fail("torrent download kept failing")
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
        self.removed = set()                 # rows the user cleared
        self.gateway = default_gateway()
        self.paused = os.path.exists(PAUSE)  # start in the current state, so a restart doesn't announce "paused" again

    def read_plist(self):
        try:
            with open(PLIST, "rb") as f:
                return plistlib.load(f).get("DownloadHistory", [])
        except Exception as e:  # Safari may be mid-write
            log(f"plist read failed ({e}); retrying next tick")
            return None

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
                self.start_curl(j)          # resumed after pause / network change
            elif j.curl_attempts < 10:
                self.takeover(j, "curl exited early")
            else:
                notify("Purrload", f"{j.name}: curl gave up after 10 attempts")
                j.state = "corrupt"
                return

        if j.state == "downloading" and not os.path.exists(j.partial) and os.path.exists(j.final):
            self.finish(j, j.final)    # Safari completed it
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
        return [j for j in self.jobs.values() if j.state in ("downloading", "failed", "takeover", "starting", "metadata")]

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
                size, sp = j.done_bytes(), j.speed() if j.state == "downloading" else 0
                tot_sp += sp
                items.append({"id": j.id, "name": j.name, "title": j.title, "state": j.state, "done": size,
                              "total": j.total, "speed": sp, "eta": (j.total - size) / sp if sp > 0 and j.total else None,
                              "folder": j.folder, "message": j.message, "files": j.files if j.state == "choosing" else None,
                              "canRetry": j.state in ("corrupt", "skipped"), "path": j.path})
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
                       "online": self.gateway is not None, "events": list(EVENTS), "jobs": items}, f)
        os.replace(tmp, STATUS_JSON)

    def take_inbox(self):
        """Start downloads the app has queued."""
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
            if "select" in msg:                      # the user's picks for a torrent
                j = self.jobs.get(msg["select"])
                if isinstance(j, DirectJob) and j.state == "choosing":
                    j.selection = [int(i) for i in msg.get("files", [])]
                    if msg.get("folder"):               # chosen just for this torrent
                        j.folder = os.path.expanduser(str(msg["folder"]))
                    j.chosen.set()
            elif "retry" in msg:
                j = self.jobs.get(msg["retry"])
                if isinstance(j, DirectJob) and j.state in ("corrupt", "skipped"):
                    del self.jobs[j.id]
                    n = DirectJob(j.url)
                    self.jobs[n.id] = n
                    log(f"{j.name}: retrying")
            elif "remove" in msg:                    # clear a finished/failed row, or cancel a torrent being chosen
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
        if self.paused and j.run:
            j.run.stop()              # the worker waits for PAUSE to go away, then resumes
        elif j.state == "downloading" and j.run and j.run.alive() and now - j.last_growth > DIRECT_HANG_SECS:
            log(f"{j.name}: no bytes for {DIRECT_HANG_SECS}s, restarting")
            j.last_growth = now
            j.run.stop()

    def run(self):
        log(f"engine started (pid {os.getpid()}, aria2 {'found' if ARIA2 else 'not found'})")
        os.makedirs(INBOX, exist_ok=True)
        while True:
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
            for _ in range(TICK if self.active() else 10):   # check the inbox every second
                time.sleep(1)
                if os.listdir(INBOX):
                    break

if __name__ == "__main__":
    # a previous engine's curls may still be writing our .part files: stop them first
    subprocess.run(["pkill", "-f", "curl -sS -L -C - --retry 30"], capture_output=True)
    Engine().run()
