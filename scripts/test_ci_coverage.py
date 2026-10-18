import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

import luau_execution_task

with patch.dict(os.environ, {
    "ROBLOX_API_KEY": "test-key",
    "ROBLOX_UNIVERSE_ID": "test-universe",
    "ROBLOX_PLACE_ID": "test-place",
}):
    import upload_and_run_task


REPO_ROOT = Path(__file__).resolve().parent.parent


class CoverageResultTests(unittest.TestCase):
    def test_writes_task_result_larger_than_log_retention_limit(self):
        report = {f"src/module{index}.luau": {"path": "x" * 500} for index in range(1000)}
        task = {"output": {"results": [report]}}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "coverage" / "coverage-final.json"
            with patch.object(upload_and_run_task, "COVERAGE_OUTPUT", output):
                with contextlib.redirect_stdout(io.StringIO()):
                    upload_and_run_task.write_coverage_report(task)
            self.assertGreater(output.stat().st_size, 450 * 1024)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), report)

    def test_rejects_missing_empty_or_invalid_task_results(self):
        outputs = [{}, {"results": []}, {"results": [None]}, {"results": [{}]},
                   {"results": ["{}"]}, {"results": [{"a": {}}, {"b": {}}]}]
        for output in outputs:
            with self.subTest(output=output):
                with self.assertRaisesRegex(RuntimeError, "non-empty coverage report"):
                    upload_and_run_task.write_coverage_report({"output": output})

    def test_complete_task_without_coverage_fails_even_when_logs_have_markers(self):
        with patch.object(upload_and_run_task, "read_file", return_value=b"return nil"), \
             patch.object(upload_and_run_task, "createTask", return_value={"path": "task"}), \
             patch.object(upload_and_run_task, "pollForTaskCompletion", return_value={"path": "task", "state": "COMPLETE"}), \
             patch.object(upload_and_run_task, "getTaskLogs", return_value="__KRF_COVERAGE_START__\n{}\n__KRF_COVERAGE_END__"), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "non-empty coverage report"):
                upload_and_run_task.run_luau_task("universe", "place", 1, "script")

    def test_failed_task_preserves_failure_and_reports_error_without_writing_coverage(self):
        task = {"path": "task", "state": "FAILED", "error": {"message": "Jest failed"}}
        errors = io.StringIO()
        with patch.object(upload_and_run_task, "read_file", return_value=b"return nil"), \
             patch.object(upload_and_run_task, "createTask", return_value={"path": "task"}), \
             patch.object(upload_and_run_task, "pollForTaskCompletion", return_value=task), \
             patch.object(upload_and_run_task, "getTaskLogs", return_value=""), \
             patch.object(upload_and_run_task, "write_coverage_report") as write_report, \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errors):
            self.assertEqual(upload_and_run_task.run_luau_task("universe", "place", 1, "script"), 1)
        write_report.assert_not_called()
        self.assertIn("Jest failed", errors.getvalue())


class TaskLogTests(unittest.TestCase):
    def test_collects_every_chunk_and_page_with_encoded_page_token(self):
        pages = [
            {"luauExecutionSessionTaskLogs": [{"messages": ["first"]}, {"messages": ["second"]}],
             "nextPageToken": "next+/="},
            {"luauExecutionSessionTaskLogs": [{"messages": ["third"]}]},
        ]
        responses = [io.BytesIO(json.dumps(page).encode()) for page in pages]
        with patch.object(luau_execution_task, "makeRequest", side_effect=responses) as request:
            self.assertEqual(luau_execution_task.getTaskLogs("key", "task"), "first\nsecond\nthird\n")
        self.assertEqual(request.call_count, 2)
        second_url = request.call_args_list[1].args[0]
        self.assertEqual(parse_qs(urlparse(second_url).query), {"pageToken": ["next+/="]})

    def test_empty_log_page_returns_empty_text(self):
        with patch.object(luau_execution_task, "makeRequest", return_value=io.BytesIO(b"{}")):
            self.assertEqual(luau_execution_task.getTaskLogs("key", "task"), "")


class CoveragePreparationTests(unittest.TestCase):
    def test_rejects_empty_or_invalid_reports_before_nyc_can_accept_them(self):
        for payload in ["{}", "[]", "null", '"coverage"', "{broken"]:
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as directory:
                input_file = Path(directory) / "coverage-final.json"
                output_file = Path(directory) / "coverage.json"
                input_file.write_text(payload, encoding="utf-8")
                result = subprocess.run(
                    ["node", str(REPO_ROOT / "scripts/prepare-nyc-coverage.cjs"), str(input_file), str(output_file)],
                    capture_output=True, text=True, cwd=REPO_ROOT,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output_file.exists())


if __name__ == "__main__":
    unittest.main()
