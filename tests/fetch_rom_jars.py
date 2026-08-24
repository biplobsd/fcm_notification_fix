#!/usr/bin/env python3
"""
Xiaomi HyperOS & MIUI Matrix Tracker and Framework Jar Fixture Downloader.
Tracks OTA versions, updates rom_matrix.json automatically, and manages
versioned test fixtures under tests/fixtures/<codename>/<version>/
"""

import os
import sys
import json
import argparse
import subprocess
import urllib.request
import urllib.error
import shutil
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
MATRIX_FILE = os.path.join(SCRIPT_DIR, "rom_matrix.json")
FIXTURES_DIR = os.path.join(SCRIPT_DIR, "fixtures")
TRACKER_YAML_URL = "https://raw.githubusercontent.com/XiaomiFirmwareUpdater/miui-updates-tracker/master/data/latest.yml"

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
            s_sz = os.path.getsize(services) // (1024 * 1024)
            m_sz = os.path.getsize(miui_services) // (1024 * 1024)
            status = f"✓ Ready ({s_sz}MB / {m_sz}MB)"
        else:
            status = "✗ Missing"

        print(f"{device:<22} {codename:<10} {ver:<25} {sdk:<4} {auto_track:<12} {status}")
    print("========================================================================================================")

def fetch_latest_ota_records():
    print("[*] Fetching latest Xiaomi OTA release database from XiaomiFirmwareUpdater...")
    try:
        req = urllib.request.Request(TRACKER_YAML_URL, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            content = resp.read().decode("utf-8")
    except Exception as e:
        print(f"[!] Failed to fetch live tracker: {e}")
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
            
            # Check if this release matches target region
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

    # Output GitHub step summary if running in CI
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

def fetch_rom_jars(target_identifier, matrix):
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
        print(f"[*] Fixture {target_arch.get('codename')}/{target_arch.get('version')} is ready ({os.path.getsize(services_path)} bytes / {os.path.getsize(miui_services_path)} bytes).")
        return True

    print(f"[!] Missing framework jars in {target_dir}/")
    print(f"    Please place services.jar and miui-services.jar into: {target_dir}/")
    return False

def extract_from_zip(zip_path, codename, version):
    if not os.path.isfile(zip_path):
        print(f"[!] File not found: {zip_path}")
        return False

    target_dir = os.path.join(FIXTURES_DIR, codename, version)
    os.makedirs(target_dir, exist_ok=True)
    print(f"[*] Inspecting ZIP archive {zip_path} for {codename} ({version})...")

    with zipfile.ZipFile(zip_path, 'r') as z:
        found_services = False
        found_miui = False
        for name in z.namelist():
            if name.endswith("framework/services.jar"):
                with z.open(name) as src, open(os.path.join(target_dir, "services.jar"), "wb") as dst:
                    shutil.copyfileobj(src, dst)
                found_services = True
                print(f"  -> Extracted services.jar from {name}")
            elif name.endswith("framework/miui-services.jar"):
                with z.open(name) as src, open(os.path.join(target_dir, "miui-services.jar"), "wb") as dst:
                    shutil.copyfileobj(src, dst)
                found_miui = True
                print(f"  -> Extracted miui-services.jar from {name}")

        if found_services and found_miui:
            meta = {"codename": codename, "version": version, "extracted_from": os.path.basename(zip_path)}
            with open(os.path.join(target_dir, "version.json"), "w", encoding="utf-8") as mf:
                json.dump(meta, mf, indent=2)
            print(f"[✓] Successfully extracted framework jars into {target_dir}")
            return True
        else:
            print("[!] Note: Direct extraction from ZIP only applies if JARs are stored uncompressed in ZIP.")
            return False

def run_tests_for_fixture():
    cmd = [os.path.join(SCRIPT_DIR, "run_ci_tests.sh")]
    res = subprocess.run(cmd, cwd=PROJECT_DIR)
    return res.returncode == 0

def main():
    parser = argparse.ArgumentParser(description="Xiaomi HyperOS Matrix Tracker & Fixture Downloader")
    parser.add_argument("--list", action="store_true", help="List all tracked ROM versions and fixture status")
    parser.add_argument("--check-latest", action="store_true", help="Query live Xiaomi OTA tracker for latest releases")
    parser.add_argument("--update-matrix", action="store_true", help="Query live OTA releases and auto-update rom_matrix.json for track_latest=true entries")
    parser.add_argument("--fetch", type=str, help="Fetch jars for specific codename, version, or 'all'")
    parser.add_argument("--extract-zip", type=str, help="Path to local recovery/update ZIP to extract JARs from")
    parser.add_argument("--codename", type=str, help="Device codename (e.g. zorn, goku)")
    parser.add_argument("--version", type=str, help="Specific version string (e.g. OS3.0.307.0.WOKCNXM.C09)")
    parser.add_argument("--test", action="store_true", help="Run integration tests after fetching")

    args = parser.parse_args()
    matrix = load_matrix()

    if args.list or len(sys.argv) == 1:
        list_tracked_roms(matrix)
        return

    if args.check_latest:
        check_and_update_matrix(matrix, auto_update=False)
        return

    if args.update_matrix:
        check_and_update_matrix(matrix, auto_update=True)
        return

    if args.extract_zip:
        if not args.codename or not args.version:
            print("[!] Please provide --codename <codename> and --version <version> when extracting from ZIP.")
            sys.exit(1)
        extract_from_zip(args.extract_zip, args.codename, args.version)
        if args.test:
            run_tests_for_fixture()
        return

    if args.fetch:
        if args.fetch.lower() == "all":
            for a in get_archetypes(matrix):
                fetch_rom_jars(a.get("codename"), matrix)
        else:
            fetch_rom_jars(args.fetch, matrix)

        if args.test:
            run_tests_for_fixture()
        return

if __name__ == "__main__":
    main()
