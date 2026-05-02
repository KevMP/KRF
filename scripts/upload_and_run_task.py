import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from luau_execution_task import createTask, getTaskLogs, pollForTaskCompletion

ROBLOX_API_KEY = os.environ["ROBLOX_API_KEY"]
ROBLOX_UNIVERSE_ID = os.environ["ROBLOX_UNIVERSE_ID"]
ROBLOX_PLACE_ID = os.environ["ROBLOX_PLACE_ID"]
COVERAGE_OUTPUT = Path("coverage/coverage-final.json")
COVERAGE_PATTERN = re.compile(
    r"__KRF_COVERAGE_START__\r?\n(?P<json>\{.*?\})\r?\n__KRF_COVERAGE_END__",
    re.DOTALL,
)

def read_file(file_path):
    with open(file_path, "rb") as file:
        return file.read()

def strip_coverage_payload(logs: str) -> str:
    return COVERAGE_PATTERN.sub(
        "[coverage] Captured Istanbul payload from Roblox test run.",
        logs,
    )

def write_coverage_report(logs: str) -> None:
    match = COVERAGE_PATTERN.search(logs)
    if not match:
        print("Coverage markers not found in Luau logs")
        return

    COVERAGE_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    COVERAGE_OUTPUT.write_text(match.group("json"), encoding="utf-8")
    print(f"Coverage report written to {COVERAGE_OUTPUT}")

def upload_place(binary_path, universe_id, place_id, do_publish=False):
    print("Uploading place to Roblox")
    version_type = "Published" if do_publish else "Saved"
    content_type = (
        "application/xml"
        if Path(binary_path).suffix.lower() == ".rbxlx"
        else "application/octet-stream"
    )

    request_headers = {
        "x-api-key": ROBLOX_API_KEY,
        "Content-Type": content_type,
        "Accept": "application/json",
    }
    url = f"https://apis.roblox.com/universes/v1/{universe_id}/places/{place_id}/versions?versionType={version_type}"
    buffer = read_file(binary_path)

    for attempt in range(1, 6):
        try:
            request = urllib.request.Request(
                url,
                data=buffer,
                headers=request_headers,
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=120) as response:
                data = json.loads(response.read().decode("utf-8"))
                place_version = data.get("versionNumber")
                if place_version is None:
                    raise RuntimeError(f"Upload response missing versionNumber: {data}")
                return int(place_version)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {error.code} uploading place:\n{body}") from error
        except (ssl.SSLEOFError, ConnectionResetError, TimeoutError, urllib.error.URLError) as error:
            if attempt == 5:
                raise RuntimeError(f"Upload failed after 5 attempts: {error}") from error

            wait = 2 ** (attempt - 1)
            print(f"Upload attempt {attempt}/5 failed ({error}). Retrying in {wait}s...")
            time.sleep(wait)

def run_luau_task(universe_id, place_id, place_version, script_file):
    print("Executing Luau task")
    script_contents = read_file(script_file).decode("utf-8")

    task = createTask(ROBLOX_API_KEY, script_contents, universe_id, place_id, place_version)
    task = pollForTaskCompletion(ROBLOX_API_KEY, task["path"])
    logs = getTaskLogs(ROBLOX_API_KEY, task["path"]) or ""

    cleaned_logs = strip_coverage_payload(logs).rstrip()
    if cleaned_logs:
        print(cleaned_logs)

    write_coverage_report(logs)
    state = task.get("state", "UNKNOWN")
    print(f"Luau task state: {state}")
    return 0 if state == "COMPLETE" else 1

if __name__ == "__main__":
    binary_file = sys.argv[1]
    script_file = sys.argv[2]

    place_version = upload_place(binary_file, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID)
    sys.exit(run_luau_task(ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID, place_version, script_file))
