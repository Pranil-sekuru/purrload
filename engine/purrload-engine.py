#!/usr/bin/env python3
"""Purrload engine: watches in-progress Safari downloads and keeps them alive.

- Keeps the Mac awake (caffeinate) while any download is active.
- Tracks real on-disk progress, speed, ETA and signed-URL expiry.
- On failure, or a stall with Safari no longer writing, takes the partial file
  over and resumes it with curl range requests (same byte offset, same URL).
- Verifies finished files (exact size + Matroska/MP4 header) and notifies.
"""
import os, re, sys, time, json, plistlib, subprocess, shutil
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
TICK = 10
STALL_SECS = 300        # no growth this long -> stalled
TAKEOVER_SECS = 300     # stalled AND Safari hasn't touched file this long -> curl takeover
EXPIRY_WARN = 1800      # warn when ETA lands within 30 min of link expiry
CURL_HANG_SECS = 60     # curl alive but no bytes this long -> restart it
PAUSE = f"{BASE}/PAUSE" # touch to pause all curl downloads, delete to resume

def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")

def notify(title, msg):
    log(f"NOTIFY {title}: {msg}")
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

class Engine:
    def __init__(self):
        self.jobs = {}
        self.caff = None
        self.volume_warned = set()
        self.gateway = default_gateway()
        self.paused = False

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
            if jid not in self.jobs and ("DownloadEntryDateFinishedKey" not in e or orphan):
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
        if not media_ok(path):
            notify("Purrload", f"{j.name}: finished but header isn't a valid video container")
            j.state = "corrupt"
            return
        j.state = "verified"
        notify("Download complete", f"{j.name} verified ({fmt_bytes(size)})")

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
        return [j for j in self.jobs.values() if j.state in ("downloading", "failed", "takeover")]

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
            size = j.size() or (os.path.getsize(j.final) if os.path.exists(j.final) else 0)
            sp = j.speed() if j.state in ("downloading", "takeover") else 0
            tot_sp += sp
            pct = 100 * size / j.total if j.total else 0
            eta = (j.total - size) / sp if sp > 0 else None
            exp = j.expiry.astimezone().strftime("%H:%M") if j.expiry else "-"
            items.append({"id": j.id, "name": j.name, "title": j.title, "state": j.state,
                          "done": size, "total": j.total, "speed": sp, "eta": eta,
                          "folder": os.path.dirname(j.final)})
            rows.append(f"{j.name:8} {j.state:11} {pct:5.1f}%  {fmt_bytes(size):>9} / {fmt_bytes(j.total):<9}"
                        f" {sp/1048576:5.2f} MB/s  ETA {fmt_dur(eta):>7}  link exp {exp}")
        rows += ["", f"total {tot_sp/1048576:.2f} MB/s"]
        with open(STATUS, "w") as f:
            f.write("\n".join(rows) + "\n")
        tmp = STATUS_JSON + ".tmp"   # write-then-rename so the bar never reads half a file
        with open(tmp, "w") as f:
            json.dump({"updated": time.time(), "speed": tot_sp, "paused": self.paused, "jobs": items}, f)
        os.replace(tmp, STATUS_JSON)

    def run(self):
        log(f"engine started (pid {os.getpid()})")
        while True:
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
                    if j.state == "takeover":
                        self.stop_curl(j, "network changed")
            for j in list(self.jobs.values()):
                try:
                    self.step(j, now)
                except Exception as e:
                    log(f"{j.name}: error {e!r}")
            self.keep_awake()
            self.write_status()
            time.sleep(TICK if self.active() else 30)

if __name__ == "__main__":
    # a previous engine's curls may still be writing our .part files: stop them first
    subprocess.run(["pkill", "-f", "curl -sS -L -C - --retry 30"], capture_output=True)
    Engine().run()
