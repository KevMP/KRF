import os
import sys
import ssl
import time
import urllib.request
import urllib.error
import json
import re
from pathlib import Path

from luau_execution_task import createTask, pollForTaskCompletion, getTaskLogs

ROBLOX_API_KEY = os.environ["ROBLOX_API_KEY"]
ROBLOX_UNIVERSE_ID = os.environ["ROBLOX_UNIVERSE_ID"]
ROBLOX_PLACE_ID = os.environ["ROBLOX_PLACE_ID"]


def read_file(file_path):
    with open(file_path, "rb") as file:
        return file.read()

def _gha_enabled():
    return os.environ.get("GITHUB_ACTIONS", "").lower() == "true"


def _gha_escape(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def gha_group(title: str):
    if _gha_enabled():
        print(f"::group::{title}")


def gha_endgroup():
    if _gha_enabled():
        print("::endgroup::")


def gha_notice(message: str):
    if _gha_enabled():
        print(f"::notice::{_gha_escape(message)}")


def gha_error(title: str, message: str):
    if _gha_enabled():
        print(f"::error title={_gha_escape(title)}::{_gha_escape(message)}")


def write_summary(md: str):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as f:
        f.write(md)
        if not md.endswith("\n"):
            f.write("\n")


def parse_jest_summary(logs: str) -> dict:
    """
    Best-effort parser for Jest-Lua output so PR summary looks clean.
    """
    out = {
        "failed_suites": None,
        "total_suites": None,
        "failed_tests": None,
        "total_tests": None,
        "fail_entries": [],
    }

    for line in logs.splitlines():
        if line.startswith(" FAIL  "):
            out["fail_entries"].append(line.replace(" FAIL  ", "").strip())

    m = re.search(r"Test Suites:\s+(\d+)\s+failed,\s+(\d+)\s+total", logs)
    if m:
        out["failed_suites"] = int(m.group(1))
        out["total_suites"] = int(m.group(2))

    m = re.search(r"Tests:\s+(\d+)\s+failed,\s+(\d+)\s+total", logs)
    if m:
        out["failed_tests"] = int(m.group(1))
        out["total_tests"] = int(m.group(2))

    return out


def upload_place(binary_path, universe_id, place_id, do_publish=False):
    print("Uploading place to Roblox")
    version_type = "Published" if do_publish else "Saved"

    # You build dist.rbxl in CI (binary). If you ever switch to .rbxlx, this stays correct.
    ext = Path(binary_path).suffix.lower()
    content_type = "application/xml" if ext == ".rbxlx" else "application/octet-stream"

    request_headers = {
        "x-api-key": ROBLOX_API_KEY,
        "Content-Type": content_type,
        "Accept": "application/json",
    }

    url = f"https://apis.roblox.com/universes/v1/{universe_id}/places/{place_id}/versions?versionType={version_type}"
    buffer = read_file(binary_path)

    max_attempts = 5
    for attempt in range(1, max_attempts + 1):
        try:
            # Make a fresh Request each attempt (safer than reusing)
            req = urllib.request.Request(url, data=buffer, headers=request_headers, method="POST")

            with urllib.request.urlopen(req, timeout=120) as response:
                data = json.loads(response.read().decode("utf-8"))
                place_version = data.get("versionNumber")
                if place_version is None:
                    raise RuntimeError(f"Upload response missing versionNumber: {data}")
                return int(place_version)

        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {e.code} uploading place:\n{body}") from e

        except (ssl.SSLEOFError, ConnectionResetError, TimeoutError, urllib.error.URLError) as e:
            # Common transient: SSL EOF / runner network blip during POST body send
            if attempt == max_attempts:
                raise RuntimeError(f"Upload failed after {max_attempts} attempts: {e}") from e

            wait = 2 ** (attempt - 1)
            print(f"Upload attempt {attempt}/{max_attempts} failed ({e}). Retrying in {wait}s...")
            time.sleep(wait)


def run_luau_task(universe_id, place_id, place_version, script_file):
    print("Executing Luau task")
    script_contents = read_file(script_file).decode("utf8")

    task = createTask(
        ROBLOX_API_KEY, script_contents, universe_id, place_id, place_version
    )
    task = pollForTaskCompletion(ROBLOX_API_KEY, task["path"])
    logs = getTaskLogs(ROBLOX_API_KEY, task["path"]) or ""

    gha_group("Luau execution logs")
    print(logs.rstrip())
    gha_endgroup()

    state = task.get("state", "UNKNOWN")
    parsed = parse_jest_summary(logs)
    passed = (state == "COMPLETE")
    icon = "✅" if passed else "❌"
    
    md = (
        "## KRF CI — Open Cloud Tests\n"
        f"{icon} **Result:** `{state}`\n\n"
    )

    if parsed["failed_suites"] is not None and parsed["total_suites"] is not None:
        md += f"\n- **Test suites:** {parsed['total_suites']} total, {parsed['failed_suites']} failed\n"
    if parsed["failed_tests"] is not None and parsed["total_tests"] is not None:
        md += f"- **Tests:** {parsed['total_tests']} total, {parsed['failed_tests']} failed\n"

    if parsed["fail_entries"]:
        md += "\n### Failing suites\n"
        for name in parsed["fail_entries"][:20]:
            md += f"- `{name}`\n"
        if len(parsed["fail_entries"]) > 20:
            md += f"- …and {len(parsed['fail_entries']) - 20} more\n"

    write_summary(md)

    if passed:
        gha_notice("Open Cloud tests passed.")
        print("Lua task completed successfully")
        sys.exit(0)

    gha_error("Open Cloud tests failed", "See 'Luau execution logs' group and the Step Summary for details.")
    print("Luau task failed", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    universe_id = ROBLOX_UNIVERSE_ID
    place_id = ROBLOX_PLACE_ID
    binary_file = sys.argv[1]
    script_file = sys.argv[2]

    place_version = upload_place(binary_file, universe_id, place_id)
    run_luau_task(universe_id, place_id, place_version, script_file)
