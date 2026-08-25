#!/usr/bin/env python3

import os
import sys
import json
import base64
import hashlib
import argparse
import subprocess
import urllib.request
import urllib.error
import shutil
import tarfile
import threading
import time
import struct
import queue

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
MATRIX_FILE = os.path.join(SCRIPT_DIR, "rom_matrix.json")
FIXTURES_DIR = os.path.join(SCRIPT_DIR, "fixtures")
DEPS_BIN_DIR = os.path.join(PROJECT_DIR, ".deps", "bin")
WORK_DIR = os.environ.get("FCM_WORK_DIR") or os.path.join(PROJECT_DIR, ".deps", "work")
TRACKER_YAML_URL = "https://raw.githubusercontent.com/XiaomiFirmwareUpdater/miui-updates-tracker/master/data/latest.yml"

PAYLOAD_DUMPER_URL = "https://github.com/ssut/payload-dumper-go/releases/download/2.0.2/payload-dumper-go_2.0.2_linux_amd64.tar.gz"
SEVEN_ZIP_URL = "https://github.com/ip7z/7zip/releases/download/24.09/7z2409-linux-x64.tar.xz"
EROFS_TOOLS_URL_X86 = "https://github.com/sekaiacg/erofs-tools/releases/download/v1.8.10-251217/erofs-utils-v1.8.10-gee46dd74-251217-Linux_x86_64.zip"
EROFS_TOOLS_URL_AARCH64 = "https://github.com/sekaiacg/erofs-tools/releases/download/v1.8.10-251217/erofs-utils-v1.8.10-gee46dd74-251217-Linux_aarch64.zip"

MIRROR_HOSTS = [
    "cdnorg.d.miui.com",
    "bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com",
    "bigota.d.miui.com",
]

JAR_PARTITIONS = ["system", "system_ext", "mi_ext"]
USER_AGENT = "Mozilla/5.0"
HTTP_TIMEOUT = 8

def load_matrix():
    if not os.path.exists(MATRIX_FILE):
        print(f"[!] ERROR: Matrix file not found at {MATRIX_FILE}")
        sys.exit(1)
    with open(MATRIX_FILE, "r", encoding="utf-8") as f:
        return json.load(f)

def save_matrix(matrix):
    with open(MATRIX_FILE, "w", encoding="utf-8") as f:
        json.dump(matrix, f, indent=2)
        f.write("\n")

def get_archetypes(matrix):
    return matrix.get("archetypes") or matrix.get("tracked_archetypes", [])

def get_fixture_path(arch):
    return os.path.join(FIXTURES_DIR, arch.get("codename", ""), arch.get("version", ""))

def _best_effort_install(package):

    if shutil.which("fsck.erofs") and package == "erofs-utils":
        return True
    for probe, install in (
        ("apt-get", ["apt-get", "install", "-y"]),
        ("pacman", ["pacman", "-S", "--noconfirm"]),
        ("dnf", ["dnf", "install", "-y"]),
    ):
        if shutil.which(probe) is None:
            continue
        try:
            res = subprocess.run(["sudo", "-n"] + install + [package],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 timeout=300)
            if res.returncode == 0:
                return True

            if os.geteuid() == 0:
                res = subprocess.run(install + [package],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     timeout=300)
                if res.returncode == 0:
                    return True
        except Exception:
            pass
    return False

def ensure_tools():

    os.makedirs(DEPS_BIN_DIR, exist_ok=True)
    env_path = os.environ.get("PATH", "")
    if DEPS_BIN_DIR not in env_path:
        os.environ["PATH"] = f"{DEPS_BIN_DIR}:{env_path}"

    payload_bin = shutil.which("payload-dumper-go")
    if not payload_bin:
        payload_dest = os.path.join(DEPS_BIN_DIR, "payload-dumper-go")
        if not os.path.isfile(payload_dest):
            print("[*] Downloading payload-dumper-go (HTTP range OTA extractor)...")
            tar_path = os.path.join(PROJECT_DIR, ".deps", "payload-dumper-go.tar.gz")
            try:
                urllib.request.urlretrieve(PAYLOAD_DUMPER_URL, tar_path)
                with tarfile.open(tar_path, "r:gz") as tar:
                    tar.extractall(DEPS_BIN_DIR)
                os.chmod(payload_dest, 0o755)
                print("[✓] Installed payload-dumper-go to .deps/bin/")
            except Exception as e:
                print(f"[!] Failed to auto-download payload-dumper-go: {e}")

    seven_zip_bin = shutil.which("7zz") or shutil.which("7z")
    if not seven_zip_bin:
        seven_zip_dest = os.path.join(DEPS_BIN_DIR, "7zz")
        if not os.path.isfile(seven_zip_dest):
            print("[*] Downloading 7zz (image & archive extractor)...")
            xz_path = os.path.join(PROJECT_DIR, ".deps", "7z.tar.xz")
            try:
                req = urllib.request.Request(SEVEN_ZIP_URL, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(req) as resp, open(xz_path, "wb") as f:
                    f.write(resp.read())
                with tarfile.open(xz_path, "r:xz") as tar:
                    tar.extractall(DEPS_BIN_DIR)
                os.chmod(seven_zip_dest, 0o755)
                print("[✓] Installed 7zz to .deps/bin/")
            except Exception as e:
                print(f"[!] Failed to auto-download 7zz: {e}")

    erofs_bin = shutil.which("extract.erofs") or shutil.which("fsck.erofs")
    if not erofs_bin:
        extract_dest = os.path.join(DEPS_BIN_DIR, "extract.erofs")
        fsck_dest = os.path.join(DEPS_BIN_DIR, "fsck.erofs")
        if not (os.path.isfile(extract_dest) or os.path.isfile(fsck_dest)):
            print("[*] Downloading erofs-tools (EROFS partition extractor)...")
            import platform
            machine = platform.machine().lower()
            erofs_url = EROFS_TOOLS_URL_AARCH64 if ("aarch64" in machine or "arm64" in machine) else EROFS_TOOLS_URL_X86
            zip_path = os.path.join(PROJECT_DIR, ".deps", "erofs-tools.zip")
            try:
                req = urllib.request.Request(erofs_url, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=20) as resp, open(zip_path, "wb") as f:
                    f.write(resp.read())
                import zipfile
                with zipfile.ZipFile(zip_path, "r") as zf:
                    for name in zf.namelist():
                        target = os.path.join(DEPS_BIN_DIR, os.path.basename(name))
                        with open(target, "wb") as out_f:
                            out_f.write(zf.read(name))
                        os.chmod(target, 0o755)
                print("[✓] Installed erofs-tools to .deps/bin/")
            except Exception as e:
                print(f"[!] Failed to auto-download erofs-tools: {e}")
                if _best_effort_install("erofs-utils") and (shutil.which("fsck.erofs") or shutil.which("extract.erofs")):
                    print("[✓] Installed erofs-utils (EROFS partition extraction).")
                else:
                    print("[!] erofs tools unavailable - EROFS partitions (HyperOS 3) cannot be extracted.")
                    print("    Install manually: sudo apt-get install erofs-utils  |  sudo pacman -S erofs-utils")

def list_tracked_roms(matrix):
    print("========================================================================================================")
    print(" TRACKED XIAOMI HYPEROS & MIUI FIRMWARE MATRIX")
    print("========================================================================================================")
    print(f"{'DEVICE':<22} {'CODENAME':<10} {'VERSION':<25} {'SDK':<4} {'AUTO-TRACK':<12} {'STATUS'}")
    print("-" * 104)

    for arch in get_archetypes(matrix):
        device = arch.get("device", "")
        codename = arch.get("codename", "")
        ver = arch.get("version", "")
        sdk = str(arch.get("sdk", ""))
        auto_track = "✓ YES" if arch.get("track_latest", False) else "— NO"

        target_dir = get_fixture_path(arch)
        services = os.path.join(target_dir, "services.jar")
        miui_services = os.path.join(target_dir, "miui-services.jar")

        if os.path.isfile(services) and os.path.isfile(miui_services):
            status = f"✓ Ready ({os.path.getsize(services)//1024} KB / {os.path.getsize(miui_services)//1024} KB)"
        else:
            status = "✗ Missing (Run --fetch to stream jars)"

        print(f"{device:<22} {codename:<10} {ver:<25} {sdk:<4} {auto_track:<12} {status}")
    print("========================================================================================================\n")

def fetch_latest_ota_records():
    print(f"[*] Querying live Xiaomi OTA releases from {TRACKER_YAML_URL}...")
    req = urllib.request.Request(TRACKER_YAML_URL, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            content = resp.read().decode("utf-8")
    except Exception as e:
        print(f"[!] Failed to fetch OTA tracker YAML: {e}")
        return []

    records = []
    current = {}
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("- "):
            if current:
                records.append(current)
            current = {}
            line = line[2:]
        if ":" in line:
            k, v = line.split(":", 1)
            current[k.strip()] = v.strip().strip("'\"")
    if current:
        records.append(current)
    return records

def check_and_update_matrix(matrix, auto_update=False):
    records = fetch_latest_ota_records()
    if not records:
        return

    tracked = {a.get("codename"): a for a in get_archetypes(matrix) if a.get("codename")}
    updates_found = []
    summary_markdown = []

    print("\n========================================================================================================")
    print(" LIVE OTA RELEASES vs MATRIX BASELINE")
    print("========================================================================================================")
    seen = set()
    for rom in records:
        rom_code = rom.get("codename", "")
        base_code = rom_code.split("_")[0] if "_" in rom_code else rom_code

        matched_arch = tracked.get(rom_code) or tracked.get(base_code)
        if matched_arch and rom.get("method") == "Recovery":
            branch = rom.get("branch", "")
            key = (rom_code, branch)
            if key in seen:
                continue
            seen.add(key)

            arch = matched_arch
            region = arch.get("region", "cn")

            rom_ver = rom.get("version", "")
            if region == "global" and ("MIXM" not in rom_ver or "Stable Beta" in branch):
                continue
            if region == "cn" and ("CNXM" not in rom_ver or "Stable Beta" in branch):
                continue

            device_name = arch.get("device")
            matrix_ver = arch.get("version")
            live_ver = rom.get("version")
            android_ver = rom.get("android")
            link = rom.get("link")
            should_track = arch.get("track_latest", False)

            is_match = live_ver in matrix_ver or matrix_ver in live_ver
            match_sym = "✓ Up-to-date" if is_match else f"⚡ New update available: {live_ver}"

            codename = arch.get("codename")
            print(f"Device: {device_name} ({codename}) [{branch}] (Auto-Track: {should_track})")
            print(f"  - Matrix Version:  {matrix_ver}")
            print(f"  - Live BigOTA:     {live_ver} (Android {android_ver}) [{match_sym}]")
            print(f"  - Download URL:    {link}\n")

            if not is_match and should_track:
                updates_found.append((arch, live_ver, link))
                summary_markdown.append(f"| {device_name} (`{codename}`) | `{matrix_ver}` | **`{live_ver}`** | Android {android_ver} | [BigOTA Download]({link}) |")

    if auto_update and updates_found:
        print(f"[*] Applying {len(updates_found)} version update(s) to rom_matrix.json...")
        for arch, new_ver, link in updates_found:
            old_ver = arch.get("version")
            arch["version"] = new_ver
            print(f"  -> Updated {arch.get('device')} ({arch.get('codename')}): {old_ver} -> {new_ver}")
        save_matrix(matrix)
        print("[✓] Saved updated tests/rom_matrix.json")

    summary_path = os.getenv("GITHUB_STEP_SUMMARY")
    if summary_path and summary_markdown:
        with open(summary_path, "a") as sf:
            sf.write("### 📲 Xiaomi HyperOS Firmware Updates Discovered\n\n")
            sf.write("| Device (Codename) | Previous Matrix Version | New Live Version | Base OS | Download Link |\n")
            sf.write("| :--- | :--- | :--- | :--- | :--- |\n")
            sf.write("\n".join(summary_markdown) + "\n")

def write_version_metadata(arch, target_dir):
    meta_path = os.path.join(target_dir, "version.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(arch, f, indent=2)

MIRROR_ALIASES = {
    "aliyun": "bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com",
    "aliyuncs": "bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com",
    "oss": "bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com",
    "sgp": "bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com",
    "cdnorg": "cdnorg.d.miui.com",
    "cdn": "cdnorg.d.miui.com",
    "bn": "bn.d.miui.com",
    "telecom": "bn.d.miui.com",
    "bigota": "bigota.d.miui.com",
    "hugeota": "hugeota.d.miui.com",
}

KNOWN_MIRRORS = [
    "bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com",
    "cdnorg.d.miui.com",
    "bn.d.miui.com",
    "hugeota.d.miui.com",
    "bigota.d.miui.com",
]

def resolve_mirror_host(mirror_input):
    if not mirror_input:
        return None
    cleaned = mirror_input.strip().lower()
    return MIRROR_ALIASES.get(cleaned, mirror_input.strip())

def build_mirror_candidates(url, preferred_mirror=None):

    from urllib.parse import urlsplit, urlunsplit
    parts = urlsplit(url)
    pref = resolve_mirror_host(preferred_mirror or os.environ.get("FCM_MIRROR"))

    hosts = []
    if pref:
        hosts.append(pref)
    for h in KNOWN_MIRRORS:
        if h not in hosts:
            hosts.append(h)
    if parts.netloc and parts.netloc not in hosts:
        hosts.append(parts.netloc)

    return [urlunsplit((parts.scheme, h, parts.path, parts.query, "")) for h in hosts]

def probe_remote_size(url):

    for range_hdr in ("bytes=0-0", "bytes=-1"):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": USER_AGENT,
                "Range": range_hdr,
            })
            with urllib.request.urlopen(req, timeout=8) as resp:
                if resp.status == 206:
                    cr = resp.headers.get("Content-Range", "")
                    if "/" in cr:
                        total = int(cr.rsplit("/", 1)[1])
                        if total > 0:
                            return total
                elif resp.status == 200 and range_hdr == "bytes=0-0":
                    cl = resp.headers.get("Content-Length", "")
                    if cl and int(cl) > 0:
                        return int(cl)
        except Exception:
            continue
    return None

def benchmark_mirror(url, sample_bytes=524288, timeout=4.0):

    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Range": f"bytes=0-{sample_bytes - 1}",
    })
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            dt = max(time.time() - t0, 1e-6)
            speed = (len(data) / dt) / (1024 * 1024)
            cr = resp.headers.get("Content-Range", "")
            total_size = int(cr.rsplit("/", 1)[1]) if "/" in cr else None
            return {
                "ok": resp.status in (200, 206) and len(data) > 0,
                "status": resp.status,
                "speed_mbps": speed,
                "ping_ms": dt * 1000,
                "size": total_size,
                "error": None,
            }
    except Exception as e:
        return {
            "ok": False,
            "status": None,
            "speed_mbps": 0.0,
            "ping_ms": 0.0,
            "size": None,
            "error": str(e),
        }

def test_all_mirrors(target_url=None):

    if not target_url:
        target_url = "https://bigota.d.miui.com/OS3.0.307.0.WOKCNXM/zorn-ota_full-OS3.0.307.0.WOKCNXM-user-16.0-7894de18a4.zip"

    from urllib.parse import urlsplit, urlunsplit
    parts = urlsplit(target_url)
    print("========================================================================================================")
    print(" XIAOMI BIGOTA MIRROR PERFORMANCE BENCHMARK & SPEED TEST")
    print("========================================================================================================")
    print(f"Sample OTA Object: {parts.path.rsplit('/', 1)[-1]}")
    print(f"{'ALIAS':<10} {'MIRROR HOST':<58} {'PING (ms)':<10} {'SPEED':<12} {'STATUS'}")
    print("-" * 104)

    alias_map = {
        "bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com": "aliyun",
        "cdnorg.d.miui.com": "cdnorg",
        "bn.d.miui.com": "bn",
        "hugeota.d.miui.com": "hugeota",
        "bigota.d.miui.com": "bigota",
    }

    results = []
    for host in KNOWN_MIRRORS:
        alias = alias_map.get(host, "custom")
        cand_url = urlunsplit((parts.scheme, host, parts.path, parts.query, ""))
        res = benchmark_mirror(cand_url, sample_bytes=1048576, timeout=6.0)
        short_host = host if len(host) <= 56 else host[:53] + "..."
        if res["ok"]:
            ping_str = f"{res['ping_ms']:.0f} ms"
            speed_str = f"{res['speed_mbps']:.2f} MB/s"
            status_str = f"✓ HTTP {res['status']}"
            results.append((res["speed_mbps"], host, alias, res))
        else:
            ping_str = "—"
            speed_str = "0.00 MB/s"
            err_msg = res["error"] or "Unreachable"
            if len(err_msg) > 20:
                err_msg = err_msg[:17] + "..."
            status_str = f"✗ {err_msg}"
        print(f"{alias:<10} {short_host:<58} {ping_str:<10} {speed_str:<12} {status_str}")

    print("========================================================================================================")
    if results:
        results.sort(key=lambda x: x[0], reverse=True)
        fastest = results[0]
        print(f"🚀 FASTEST MIRROR: {fastest[1]} (Alias: '{fastest[2]}', {fastest[0]:.2f} MB/s)")
        print(f"   Usage: python3 tests/fetch_rom_jars.py --mirror {fastest[2]} --fetch <device>")
    print("========================================================================================================\n")

def pick_and_rank_mirrors(base_url, preferred_mirror=None):

    from urllib.parse import urlsplit, urlunsplit
    parts = urlsplit(base_url)
    pref_host = resolve_mirror_host(preferred_mirror or os.environ.get("FCM_MIRROR"))

    hosts_to_try = []
    if pref_host:
        hosts_to_try.append(pref_host)
    for h in KNOWN_MIRRORS:
        if h not in hosts_to_try:
            hosts_to_try.append(h)
    if parts.netloc and parts.netloc not in hosts_to_try:
        hosts_to_try.append(parts.netloc)

    print("[*] Probing and ranking Xiaomi OTA mirrors for maximum throughput...")
    tested = []
    total_size = None

    for host in hosts_to_try:
        cand_url = urlunsplit((parts.scheme, host, parts.path, parts.query, ""))
        bench = benchmark_mirror(cand_url, sample_bytes=262144, timeout=3.5)
        if bench["ok"]:
            if total_size is None and bench["size"]:
                total_size = bench["size"]
            tested.append((bench["speed_mbps"], cand_url, host))
            short_host = host if len(host) <= 48 else host[:45] + "..."
            print(f"  -> {short_host:<48} : {bench['speed_mbps']:5.2f} MB/s (ping {bench['ping_ms']:4.0f}ms)")
        else:
            sz = probe_remote_size(cand_url)
            if sz:
                if total_size is None:
                    total_size = sz
                tested.append((0.02, cand_url, host))
                short_host = host if len(host) <= 48 else host[:45] + "..."
                print(f"  -> {short_host:<48} : ~0.02 MB/s (throttled origin)")

    if not tested:
        return [], None

    fast_tested = [t for t in tested if t[0] >= 0.2]
    if fast_tested:
        tested = fast_tested

    if pref_host:
        pref_matches = [u for s, u, h in tested if h == pref_host]
        other_matches = [u for s, u, h in sorted(tested, key=lambda x: x[0], reverse=True) if h != pref_host]
        ranked_urls = pref_matches + other_matches
    else:
        tested.sort(key=lambda x: x[0], reverse=True)
        ranked_urls = [u for s, u, h in tested]

    primary_host = urlsplit(ranked_urls[0]).netloc
    print(f"[✓] Selected primary mirror: {primary_host} ({len(ranked_urls)} high-speed mirrors active)")
    return ranked_urls, total_size

class RangeClient:

    def __init__(self, url):
        self.url = url

    def _open(self, start=None, end=None, suffix=None, max_retries=3):
        headers = {"User-Agent": USER_AGENT}
        if suffix is not None:
            headers["Range"] = f"bytes=-{suffix}"
        elif start is not None and end is not None:
            headers["Range"] = f"bytes={start}-{end}"
        elif start is not None:
            headers["Range"] = f"bytes={start}-"

        last_err: Exception = RuntimeError(f"Failed to connect to {self.url}")
        for attempt in range(max_retries):
            try:
                req = urllib.request.Request(self.url, headers=headers)
                resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT)
                if (start is not None or suffix is not None) and resp.status != 206:
                    resp.close()
                    raise RuntimeError(
                        f"{self.url} ignored HTTP Range (status {resp.status}); "
                        "mirror does not support partial downloads")
                return resp
            except Exception as e:
                last_err = e
                if attempt + 1 < max_retries:
                    time.sleep(0.3 * (2 ** attempt))
        raise last_err

    def read_range(self, start, end):
        with self._open(start=start, end=end) as resp:
            return resp.read()

    def read_suffix(self, n):
        with self._open(suffix=n) as resp:
            return resp.read()

class HttpRangeZipReader:

    def __init__(self, client, candidate_urls=None):
        self.client = client
        self.candidate_urls = candidate_urls or [client.url]
        self.entries = {}
        self._load_central_directory()

    def _load_central_directory(self):
        try:
            tail = self.client.read_suffix(65536)
            eocd_idx = tail.rfind(b"\x50\x4b\x05\x06")
            if eocd_idx == -1:
                tail = self.client.read_suffix(262144)
                eocd_idx = tail.rfind(b"\x50\x4b\x05\x06")
            if eocd_idx == -1:
                raise RuntimeError("EOCD signature not found in archive tail")

            cd_size, cd_offset = struct.unpack_from("<II", tail, eocd_idx + 12)

            loc_idx = tail.rfind(b"\x50\x4b\x06\x07")
            if loc_idx != -1:
                eocd64_offset = struct.unpack_from("<Q", tail, loc_idx + 8)[0]
                eocd64 = self.client.read_range(eocd64_offset, eocd64_offset + 55)
                cd_size, cd_offset = struct.unpack_from("<QQ", eocd64, 40)

            cd_bytes = self.client.read_range(cd_offset, cd_offset + cd_size - 1)
            pos = 0
            while pos + 46 <= len(cd_bytes):
                if cd_bytes[pos:pos+4] != b"\x50\x4b\x01\x02":
                    break
                comp_size, uncomp_size = struct.unpack_from("<II", cd_bytes, pos + 20)
                name_len, extra_len = struct.unpack_from("<HH", cd_bytes, pos + 28)
                rel_offset = struct.unpack_from("<I", cd_bytes, pos + 42)[0]
                filename = cd_bytes[pos+46:pos+46+name_len].decode("utf-8", "ignore")

                if rel_offset == 0xffffffff or uncomp_size == 0xffffffff or comp_size == 0xffffffff:
                    extra_data = cd_bytes[pos+46+name_len:pos+46+name_len+extra_len]
                    epos = 0
                    offset_in_block = 0
                    while epos + 4 <= len(extra_data):
                        tag, block_sz = struct.unpack_from("<HH", extra_data, epos)
                        if tag == 0x0001:
                            offset_in_block = epos + 4
                            if uncomp_size == 0xffffffff:
                                uncomp_size = struct.unpack_from("<Q", extra_data, offset_in_block)[0]
                                offset_in_block += 8
                            if comp_size == 0xffffffff:
                                comp_size = struct.unpack_from("<Q", extra_data, offset_in_block)[0]
                                offset_in_block += 8
                            if rel_offset == 0xffffffff:
                                rel_offset = struct.unpack_from("<Q", extra_data, offset_in_block)[0]
                            break
                        epos += 4 + block_sz

                self.entries[filename] = {
                    "name": filename,
                    "comp_size": comp_size,
                    "uncomp_size": uncomp_size,
                    "local_header_offset": rel_offset,
                }
                pos += 46 + name_len + extra_len
        except Exception as e:
            print(f"[!] Warning: HTTP Range ZIP inspection error: {e}")

    def download_file_range(self, filename, dest_path, workers=None):
        if filename not in self.entries:
            return False
        entry = self.entries[filename]
        header_offset = entry["local_header_offset"]
        comp_size = entry["comp_size"]

        local_header = self.client.read_range(header_offset, header_offset + 29)
        name_len, extra_len = struct.unpack_from("<HH", local_header, 26)
        data_offset = header_offset + 30 + name_len + extra_len

        urls = list(self.candidate_urls)
        for cand in build_mirror_candidates(self.client.url):
            if cand not in urls:
                urls.append(cand)

        if comp_size <= 8 * 1024 * 1024:
            for u in urls:
                try:
                    rc = RangeClient(u)
                    data = rc.read_range(data_offset, data_offset + comp_size - 1)
                    if len(data) == comp_size:
                        with open(dest_path, "wb") as f:
                            f.write(data)
                        return True
                except Exception:
                    continue
            return False

        return ParallelRangeDownloader(
            urls, dest_path, comp_size,
            absolute_start=data_offset, workers=workers,
            label=filename,
        ).run()

class ParallelRangeDownloader:

    CHUNK_SIZE = 8 * 1024 * 1024
    READ_CHUNK = 256 * 1024

    def __init__(self, urls, dest_path, size, absolute_start=0, workers=None, label=None):
        self.urls = [urls] if isinstance(urls, str) else list(urls)
        self.dest_path = dest_path
        self.size = size
        self.absolute_start = absolute_start
        self.state_path = dest_path + ".progress"
        self.label = label or os.path.basename(dest_path)
        if workers is None:
            try:
                workers = int(os.environ.get("FCM_DL_WORKERS", "12"))
            except ValueError:
                workers = 12
        self.workers = max(1, min(workers, 64))
        self.chunk_size = self.CHUNK_SIZE
        self.total_chunks = (size + self.chunk_size - 1) // self.chunk_size
        self.fingerprint = hashlib.sha256(
            f"{self.urls[0]}:{self.size}:{self.absolute_start}:{self.chunk_size}".encode()
        ).hexdigest()[:16]
        self.done_chunks = set()
        self.downloaded = 0
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.last_progress = time.time()

    def _load_state(self):
        if not os.path.exists(self.state_path):
            self.done_chunks = set()
            return

        try:
            with open(self.state_path, "r", encoding="utf-8") as f:
                state = json.load(f)
            url_match = state.get("url") == self.urls[0] or state.get("fingerprint") == self.fingerprint
            if (url_match and
                state.get("size") == self.size and
                state.get("absolute_start") == self.absolute_start and
                state.get("chunk_size") == self.chunk_size):
                self.done_chunks = set(i for i in state.get("done", []) if 0 <= i < self.total_chunks)
                return
        except Exception:
            pass

        self.done_chunks = set()
        try:
            os.remove(self.state_path)
        except OSError:
            pass
        if os.path.exists(self.dest_path):
            try:
                os.remove(self.dest_path)
            except OSError:
                pass

    def _save_state(self):
        tmp = self.state_path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({
                    "fingerprint": self.fingerprint,
                    "url": self.urls[0],
                    "size": self.size,
                    "absolute_start": self.absolute_start,
                    "chunk_size": self.chunk_size,
                    "done": sorted(self.done_chunks),
                }, f)
            os.replace(tmp, self.state_path)
        except OSError:
            pass

    def _worker(self, wid, fd, work_queue):
        consecutive_failures = 0

        while not self.stop.is_set() and len(self.done_chunks) < self.total_chunks:
            try:
                idx = work_queue.get(timeout=0.5)
            except queue.Empty:
                if len(self.done_chunks) == self.total_chunks:
                    return
                continue

            if idx in self.done_chunks:
                work_queue.task_done()
                continue

            start = idx * self.chunk_size
            end = min(start + self.chunk_size - 1, self.size - 1)
            success = False

            for attempt in range(len(self.urls) * 2):
                if self.stop.is_set():
                    break
                url = self.urls[(wid + attempt + idx) % len(self.urls)]
                pos = start
                try:
                    client = RangeClient(url)
                    resp = client._open(start=self.absolute_start + pos,
                                        end=self.absolute_start + end,
                                        max_retries=1)
                    with resp:
                        while pos <= end and not self.stop.is_set():
                            want = min(self.READ_CHUNK, end - pos + 1)
                            t_read = time.time()
                            chunk = resp.read(want)
                            if not chunk:
                                break
                            read_dt = max(time.time() - t_read, 1e-6)

                            if len(chunk) == want and (len(chunk) / read_dt) < 150 * 1024:
                                break
                            os.pwrite(fd, chunk, pos)
                            pos += len(chunk)
                            with self.lock:
                                self.downloaded += len(chunk)

                    if pos > end:
                        with self.lock:
                            self.done_chunks.add(idx)
                            self.last_progress = time.time()
                        if idx % 8 == 0 or len(self.done_chunks) == self.total_chunks:
                            self._save_state()
                        success = True
                        consecutive_failures = 0
                        break
                except Exception:
                    time.sleep(0.1)

            if success:
                work_queue.task_done()
            else:
                consecutive_failures += 1
                if not self.stop.is_set() and idx not in self.done_chunks:
                    work_queue.put(idx)
                    work_queue.task_done()
                    time.sleep(min(0.2 * consecutive_failures, 2.0))

    def _progress_printer(self):
        t0 = time.time()
        last = self.downloaded
        while not self.stop.wait(1.0):
            now = self.downloaded
            dt = max(time.time() - t0, 1e-6)
            rate = (now - last) / dt
            pct = min(now / max(self.size, 1), 1.0) * 100
            sys.stdout.write(
                f"\r  -> {self.label}: {pct:5.1f}% ({now//1048576}/{self.size//1048576} MB, "
                f"{max(rate, 0)/1048576:.2f} MB/s, {len(self.done_chunks)}/{self.total_chunks} chunks)   ")
            sys.stdout.flush()
            last = now
            t0 = time.time()

            if time.time() - self.last_progress > 180 and len(self.done_chunks) < self.total_chunks:
                print("\n[!] Global download stall detected (no progress for 180s).")
                self.stop.set()
                break

    def run(self):
        self._load_state()
        resumed = sum(min(self.chunk_size, self.size - i * self.chunk_size) for i in self.done_chunks)
        if self.done_chunks:
            print(f"[*] Resuming {self.label}: {len(self.done_chunks)}/{self.total_chunks} "
                  f"chunks already present (~{resumed//1048576} MB).")
            self.downloaded = min(resumed, self.size)

        fd = os.open(self.dest_path, os.O_CREAT | os.O_RDWR, 0o644)
        os.ftruncate(fd, self.size)

        work_queue = queue.Queue()
        for i in range(self.total_chunks):
            if i not in self.done_chunks:
                work_queue.put(i)

        worker_count = min(self.workers, max(1, self.total_chunks - len(self.done_chunks)))
        progress = threading.Thread(target=self._progress_printer, daemon=True)
        progress.start()

        threads = [threading.Thread(target=self._worker, args=(i, fd, work_queue), daemon=True)
                   for i in range(max(worker_count, 1))]
        for t in threads:
            t.start()

        try:
            for t in threads:
                t.join()
        except KeyboardInterrupt:
            print("\n[!] Download interrupted by user.")
            self.stop.set()
        finally:
            self.stop.set()
            os.fsync(fd)
            os.close(fd)
            sys.stdout.write("\n")

        ok = len(self.done_chunks) == self.total_chunks
        if ok and os.path.isfile(self.dest_path):
            actual = os.path.getsize(self.dest_path)
            ok = (actual == self.size)
            if ok:
                try:
                    os.remove(self.state_path)
                except OSError:
                    pass

        if not ok:
            self._save_state()
            print(f"[!] Download incomplete for {self.label} "
                  f"({len(self.done_chunks)}/{self.total_chunks} chunks). "
                  "Progress saved; re-run to resume.")
        return ok

EROFS_MAGIC = b"\xe2\xe1\xf5\xe0"

def _is_erofs(img_path):
    try:
        with open(img_path, "rb") as f:
            f.seek(1024)
            return f.read(4) == EROFS_MAGIC
    except OSError:
        return False

def _extract_with_7zz(img_path, out_dir):
    seven_zip = shutil.which("7zz") or shutil.which("7z") or os.path.join(DEPS_BIN_DIR, "7zz")
    if not os.path.isfile(seven_zip):
        return False
    os.makedirs(out_dir, exist_ok=True)
    cmd = [seven_zip, "x", "-y", "-r", f"-o{out_dir}", img_path,
           "services.jar", "miui-services.jar",
           "*framework/services.jar", "*framework/miui-services.jar"]
    res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return res.returncode in (0, 1) or (os.path.exists(out_dir) and bool(os.listdir(out_dir)))

def _extract_with_erofs(img_path, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    extract_bin = shutil.which("extract.erofs") or os.path.join(DEPS_BIN_DIR, "extract.erofs")
    fsck_bin = shutil.which("fsck.erofs") or os.path.join(DEPS_BIN_DIR, "fsck.erofs")

    if extract_bin and os.path.isfile(extract_bin):
        # Use targeted fast extraction with extract.erofs
        subpaths = ["/framework", "/system/framework", "/system_ext/framework", "/mi_ext/framework", "/product/framework", "/odm/framework"]
        extracted_any = False
        for sp in subpaths:
            cmd = [extract_bin, "-i", img_path, "-X", sp, "-o", out_dir, "-s", "-f"]
            res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if res.returncode == 0 and os.path.exists(out_dir) and bool(os.listdir(out_dir)):
                extracted_any = True
        if extracted_any:
            return True

        # Fallback to full extraction with extract.erofs
        cmd = [extract_bin, "-i", img_path, "-x", "-o", out_dir, "-s", "-f"]
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0 and os.path.exists(out_dir) and bool(os.listdir(out_dir)):
            return True

    if fsck_bin and os.path.isfile(fsck_bin):
        cmd = [fsck_bin, f"--extract={out_dir}", "--no-sbcrc", "--overwrite", "--no-preserve", "--no-xattrs", img_path]
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return res.returncode == 0 or (os.path.exists(out_dir) and bool(os.listdir(out_dir)))

    return False

def extract_jars_from_partition_images(images_dir, target_dir, keep_temp=False):

    found_services = False
    found_miui = False

    target_services = os.path.join(target_dir, "services.jar")
    target_miui = os.path.join(target_dir, "miui-services.jar")

    img_files = []
    for root, _, files in os.walk(images_dir):
        for img in files:
            if img.endswith(".img"):
                img_files.append(os.path.join(root, img))

    # Prioritize system_ext, system, mi_ext before huge product/odm partitions
    def _img_priority(p):
        name = os.path.basename(p).lower()
        if "system_ext" in name:
            return 0
        if "system." in name or "system_" in name:
            return 1
        if "mi_ext" in name:
            return 2
        return 10
    img_files.sort(key=_img_priority)

    for img_path in img_files:
        if found_services and found_miui:
            break
        img_name = os.path.basename(img_path)
        tmp_extract = os.path.join(images_dir, f"ext_{img_name}")
        shutil.rmtree(tmp_extract, ignore_errors=True)

        if _is_erofs(img_path):
            print(f"  -> {img_name}: EROFS filesystem detected, extracting with erofs-tools...")
            ok = _extract_with_erofs(img_path, tmp_extract)
        else:
            print(f"  -> {img_name}: ext4 detected, extracting with 7zz...")
            ok = _extract_with_7zz(img_path, tmp_extract)
            if not ok and (shutil.which("extract.erofs") or shutil.which("fsck.erofs")):
                ok = _extract_with_erofs(img_path, tmp_extract)

        if not os.path.exists(tmp_extract) or not os.listdir(tmp_extract):
            continue

        for r, _, f_list in os.walk(tmp_extract):
            for f in f_list:
                src = os.path.join(r, f)
                if f == "services.jar" and not found_services and os.path.getsize(src) > 1024:
                    shutil.copy2(src, target_services)
                    found_services = True
                    print(f"  -> Extracted services.jar ({os.path.getsize(src)//1024} KB) from {img_name}")
                elif f == "miui-services.jar" and not found_miui and os.path.getsize(src) > 1024:
                    shutil.copy2(src, target_miui)
                    found_miui = True
                    print(f"  -> Extracted miui-services.jar ({os.path.getsize(src)//1024} KB) from {img_name}")
            if found_services and found_miui:
                break
        if not keep_temp:
            shutil.rmtree(tmp_extract, ignore_errors=True)

    return found_services and found_miui

def check_disk_space(path, needed_bytes):
    free = shutil.disk_usage(path).free
    if free < needed_bytes:
        print(f"[!] Insufficient disk space at {path}: "
              f"{free//2**30} GB free, ~{needed_bytes//2**30} GB required.")
        print("    Set FCM_WORK_DIR to a location with more space and retry.")
        return False
    return True

def _read_payload_expected_hash(zip_reader, work_dir):

    prop_entry = zip_reader.entries.get("payload_properties.txt")
    if not prop_entry:
        return None
    tmp = os.path.join(work_dir, "payload_properties.txt")
    try:
        if not zip_reader.download_file_range("payload_properties.txt", tmp, workers=1):
            return None
        with open(tmp, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("FILE_HASH="):
                    return line.split("=", 1)[1].strip()
    except Exception:
        pass
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    return None

def stream_and_extract_remote_ota(ota_url, target_dir, preferred_mirror=None, workers=None, keep_payload=False):

    ensure_tools()
    os.makedirs(target_dir, exist_ok=True)

    print(f"[*] Inspecting remote Recovery OTA via HTTP Range...")
    print(f"    Target URL: {ota_url}")

    ranked_urls, total_size = pick_and_rank_mirrors(ota_url, preferred_mirror=preferred_mirror)
    if not ranked_urls:
        print("[!] No responsive mirror found for this OTA URL.")
        return False

    work_url = ranked_urls[0]
    zip_reader = HttpRangeZipReader(RangeClient(work_url), candidate_urls=ranked_urls)
    if not zip_reader.entries:
        print("[!] Could not parse remote ZIP central directory.")
        return False

    print(f"[*] Remote ZIP parsed successfully ({len(zip_reader.entries)} entries in remote archive).")

    direct_services = [k for k in zip_reader.entries if k.endswith("framework/services.jar")]
    direct_miui = [k for k in zip_reader.entries if k.endswith("framework/miui-services.jar")]

    if direct_services and direct_miui:
        s_entry = zip_reader.entries[direct_services[0]]
        m_entry = zip_reader.entries[direct_miui[0]]
        if s_entry["comp_size"] == s_entry["uncomp_size"] and m_entry["comp_size"] == m_entry["uncomp_size"]:
            print("[*] Found STORED framework JARs in remote ZIP! Streaming directly...")
            ok_s = zip_reader.download_file_range(direct_services[0], os.path.join(target_dir, "services.jar"), workers=workers)
            ok_m = zip_reader.download_file_range(direct_miui[0], os.path.join(target_dir, "miui-services.jar"), workers=workers)
            if ok_s and ok_m:
                return True
            print("[!] Direct JAR streaming failed - falling back to payload route.")

    payload_entry = zip_reader.entries.get("payload.bin")
    if payload_entry and payload_entry["comp_size"] != payload_entry["uncomp_size"]:
        print("[!] payload.bin is compressed inside the ZIP - unsupported variant.")
        return False

    if payload_entry:
        print(f"[*] Modern HyperOS Recovery ROM detected (payload.bin, "
              f"{payload_entry['comp_size']/2**30:.2f} GB).")
        os.makedirs(WORK_DIR, exist_ok=True)

        final_payload = os.path.join(WORK_DIR, "payload.bin")
        dump_dir = os.path.join(WORK_DIR, "dumped")

        if os.path.isfile(final_payload) and os.path.getsize(final_payload) == payload_entry["comp_size"]:
            print(f"[*] Reusing existing payload.bin ({os.path.getsize(final_payload)//1048576} MB) from {final_payload}")
        else:
            needed = payload_entry["comp_size"] * 2 + 2**30
            if not check_disk_space(WORK_DIR, needed):
                return False

            expected_hash = _read_payload_expected_hash(zip_reader, WORK_DIR)

            for attempt in (1, 2):
                payload_path = os.path.join(WORK_DIR, "payload.bin.part")
                ok = zip_reader.download_file_range("payload.bin", payload_path, workers=workers)
                if ok and expected_hash:
                    h = hashlib.sha256()
                    with open(payload_path, "rb") as pf:
                        for block in iter(lambda: pf.read(8 * 1024 * 1024), b""):
                            h.update(block)
                    actual = base64.b64encode(h.digest()).decode()
                    if actual != expected_hash:
                        if attempt < 2:
                            print(f"[!] payload.bin SHA256 mismatch (attempt {attempt}) - retrying.")
                        else:
                            print("[!] payload.bin SHA256 mismatch - aborting.")
                        for p in (payload_path, payload_path + ".progress"):
                            if os.path.exists(p):
                                try:
                                    os.remove(p)
                                except OSError:
                                    pass
                        continue
                    print("[✓] payload.bin SHA256 verified.")
                if not ok:
                    print("[!] payload.bin download failed.")
                    return False
                os.replace(payload_path, final_payload)
                break
            else:
                return False

        payload_dumper = shutil.which("payload-dumper-go") or os.path.join(DEPS_BIN_DIR, "payload-dumper-go")
        if not os.path.isfile(payload_dumper):
            print("[!] payload-dumper-go unavailable; cannot dump partitions.")
            return False

        workers_count = str(min(os.cpu_count() or 4, 16))
        print(f"[*] Dumping framework-bearing partitions from payload.bin ({','.join(JAR_PARTITIONS)})...")
        shutil.rmtree(dump_dir, ignore_errors=True)
        os.makedirs(dump_dir, exist_ok=True)
        cmd = [payload_dumper, "-c", workers_count, "-no-verify", "-p", ",".join(JAR_PARTITIONS),
               "-o", dump_dir, final_payload]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

        if res.returncode != 0:
            print("[!] payload-dumper-go failed:")
            print("\n".join(res.stdout.splitlines()[-15:]))
            if not keep_payload:
                shutil.rmtree(dump_dir, ignore_errors=True)
            return False

        print("[*] Extracting services.jar and miui-services.jar from partition images...")
        success = extract_jars_from_partition_images(dump_dir, target_dir, keep_temp=keep_payload)

        if not success:
            fallback_partitions = ["product", "odm"]
            print("[*] Primary partitions did not yield both JARs. Dumping secondary partitions (product, odm)...")
            cmd_fb = [payload_dumper, "-c", workers_count, "-no-verify", "-p", ",".join(fallback_partitions),
                      "-o", dump_dir, final_payload]
            res_fb = subprocess.run(cmd_fb, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if res_fb.returncode == 0:
                success = extract_jars_from_partition_images(dump_dir, target_dir, keep_temp=keep_payload)

        if not keep_payload:
            shutil.rmtree(dump_dir, ignore_errors=True)
            try:
                os.remove(final_payload)
            except OSError:
                pass
        else:
            print(f"[*] Preserving dumped partitions: {dump_dir}")
            print(f"[*] Preserving payload file: {final_payload}")

        if success:
            print(f"[✓] Successfully extracted framework JARs -> {target_dir}")
            return True

    print("[!] No usable extraction path found for this OTA.")
    return False

def fetch_rom_jars(target_identifier, matrix, preferred_mirror=None, workers=None, keep_payload=False):
    target_arch = None
    for a in get_archetypes(matrix):
        if a.get("codename") == target_identifier or a.get("version") == target_identifier:
            target_arch = a
            break

    if not target_arch:
        print(f"[!] Unknown target identifier: {target_identifier}")
        return False

    target_dir = get_fixture_path(target_arch)
    services_path = os.path.join(target_dir, "services.jar")
    miui_services_path = os.path.join(target_dir, "miui-services.jar")

    if os.path.isfile(services_path) and os.path.isfile(miui_services_path):
        write_version_metadata(target_arch, target_dir)
        print(f"[*] Fixture {target_arch.get('codename')}/{target_arch.get('version')} is ready "
              f"({os.path.getsize(services_path)} bytes / {os.path.getsize(miui_services_path)} bytes).")
        return True

    print(f"[*] Fixture {target_arch.get('codename')} ({target_arch.get('version')}) is missing locally.")
    print("[*] Resolving official BigOTA download URL from Xiaomi tracker...")
    records = fetch_latest_ota_records()

    base_code = target_arch.get("codename", "").split("_")[0]
    exact_matches = []
    fallback_matches = []
    for r in records:
        rom_code = r.get("codename", "")
        if rom_code.split("_")[0] != base_code or r.get("method") != "Recovery":
            continue
        link = r.get("link")
        if not link:
            continue
        live_ver = r.get("version", "")
        matrix_ver = target_arch.get("version", "")
        if matrix_ver in live_ver or live_ver in matrix_ver:
            exact_matches.append(link)
        else:
            fallback_matches.append(link)

    target_link = None
    if exact_matches:
        target_link = exact_matches[0]
    elif fallback_matches:
        print("[!] Note: no version-exact OTA found; using latest stable release instead.")
        target_link = fallback_matches[0]

    if not target_link:
        print(f"[!] No Recovery OTA found on tracker for codename '{target_arch.get('codename')}'.")
        return False

    print(f"\n[*] Streaming target Recovery OTA...")
    if stream_and_extract_remote_ota(target_link, target_dir, preferred_mirror=preferred_mirror, workers=workers, keep_payload=keep_payload):
        write_version_metadata(target_arch, target_dir)
        return True

    print(f"\n[!] Unable to stream jars for {target_arch.get('codename')}. Stopping.")
    return False

def run_tests_for_fixture():
    cmd = [os.path.join(SCRIPT_DIR, "run_ci_tests.sh")]
    res = subprocess.run(cmd, cwd=PROJECT_DIR)
    return res.returncode == 0

def main():
    parser = argparse.ArgumentParser(description="Xiaomi HyperOS Matrix Tracker & HTTP Range Jar Streamer")
    parser.add_argument("--list", action="store_true", help="List all tracked ROM versions and fixture status")
    parser.add_argument("--check-latest", action="store_true", help="Query live Xiaomi OTA tracker for latest releases")
    parser.add_argument("--update-matrix", action="store_true", help="Query live OTA releases and auto-update rom_matrix.json for track_latest=true entries")
    parser.add_argument("--fetch", type=str, help="Fetch jars for specific codename, version, or 'all' using smart HTTP Range streaming")
    parser.add_argument("--url", type=str, help="Directly stream and extract framework JARs from a remote BigOTA HTTP URL")
    parser.add_argument("--codename", type=str, help="Device codename (e.g. zorn, goku)")
    parser.add_argument("--version", type=str, help="Specific version string (e.g. OS3.0.307.0.WOKCNXM.C09)")
    parser.add_argument("--mirror", type=str, help="Force mirror (e.g. 'aliyun', 'cdnorg', 'bn', 'bigota', or full hostname)")
    parser.add_argument("-w", "--workers", type=int, default=None, help="Number of parallel range download workers (default: 24)")
    parser.add_argument("--test-mirrors", nargs="?", const="default", help="Benchmark and speed-test all known Xiaomi mirror servers")
    parser.add_argument("--keep-payload", "--keep-temp", dest="keep_payload", action="store_true", default=bool(os.environ.get("FCM_KEEP_PAYLOAD")), help="Do not delete downloaded payload.bin or dumped partition images (for debugging/testing extraction)")
    parser.add_argument("--test", action="store_true", help="Run integration tests after fetching")

    args = parser.parse_args()

    if args.test_mirrors is not None:
        target = None if (args.test_mirrors == "default" or not args.test_mirrors.startswith("http")) else args.test_mirrors
        test_all_mirrors(target)
        return

    matrix = load_matrix()

    if args.list:
        list_tracked_roms(matrix)
        return

    if args.url:
        cname = args.codename or "custom_device"
        ver = args.version or "custom_version"
        target_dir = os.path.join(FIXTURES_DIR, cname, ver)
        stream_and_extract_remote_ota(args.url, target_dir, preferred_mirror=args.mirror, workers=args.workers, keep_payload=args.keep_payload)
        if args.test:
            run_tests_for_fixture()
        return

    if args.check_latest:
        check_and_update_matrix(matrix, auto_update=False)
        return

    if args.update_matrix:
        check_and_update_matrix(matrix, auto_update=True)
        return

    if args.fetch:
        if args.fetch.lower() == "all":
            results = {}
            for a in get_archetypes(matrix):
                results[a.get("codename")] = fetch_rom_jars(
                    a.get("codename"), matrix,
                    preferred_mirror=args.mirror,
                    workers=args.workers,
                    keep_payload=args.keep_payload
                )
            failed = [k for k, v in results.items() if not v]
            if failed:
                print(f"\n[!] Failed fixtures: {', '.join(failed)}")
                sys.exit(1)
        else:
            if not fetch_rom_jars(args.fetch, matrix, preferred_mirror=args.mirror, workers=args.workers, keep_payload=args.keep_payload):
                sys.exit(1)

        if args.test:
            run_tests_for_fixture()
        return

    list_tracked_roms(matrix)

if __name__ == "__main__":
    main()
