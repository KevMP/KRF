import json
import os
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

def read_file(file_path):
    with open(file_path, "rb") as file:
        return file.read()

def write_coverage_report(task) -> None:
    results = task.get("output", {}).get("results", [])
    if len(results) != 1 or not isinstance(results[0], dict) or not results[0]:
        raise RuntimeError("Luau task did not return a non-empty coverage report")

    COVERAGE_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    COVERAGE_OUTPUT.write_text(json.dumps(results[0]), encoding="utf-8")
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

    if logs.rstrip():
        print(logs.rstrip())

    state = task.get("state", "UNKNOWN")
    print(f"Luau task state: {state}")
    if state != "COMPLETE":
        print(f"Luau task failed: {json.dumps(task.get('error', {}))}", file=sys.stderr)
        return 1

    write_coverage_report(task)
    return 0

if __name__ == "__main__":
    binary_file = sys.argv[1]
    script_file = sys.argv[2]

    COVERAGE_OUTPUT.unlink(missing_ok=True)
    place_version = upload_place(binary_file, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID)
    sys.exit(run_luau_task(ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID, place_version, script_file))
