#!/usr/bin/env python3
import argparse
import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional


@dataclass
class CheckResult:
    name: str
    passed: int = 0
    total: int = 0
    details: List[str] = field(default_factory=list)

    def add(self, ok: bool, detail: str) -> None:
        self.total += 1
        if ok:
            self.passed += 1
        self.details.append(("PASS" if ok else "FAIL") + " " + detail)

    @property
    def score(self) -> float:
        return 1.0 if self.total == 0 else self.passed / self.total


@dataclass
class CaseScore:
    case_id: str
    name: str
    checks: List[CheckResult]

    @property
    def passed(self) -> int:
        return sum(c.passed for c in self.checks)

    @property
    def total(self) -> int:
        return sum(c.total for c in self.checks)

    @property
    def score(self) -> float:
        return 0.0 if self.total == 0 else self.passed / self.total


def load_json(path: Path) -> Any:
    with path.open() as f:
        return json.load(f)


def normalize_text(value: Optional[str]) -> str:
    return " ".join((value or "").lower().split())


def contains_all(text: str, needles: List[str]) -> bool:
    hay = normalize_text(text)
    return all(normalize_text(n) in hay for n in needles)


def parse_dt(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


WEEKDAYS = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}


def resolve_relative_date(marker: str, reference: datetime) -> str:
    key = marker.removeprefix("relative:").lower()
    base = reference.date()
    if key == "tomorrow":
        return (base + timedelta(days=1)).isoformat()
    if key.startswith("next_"):
        key = key[len("next_"):]
    if key in WEEKDAYS:
        current = base.weekday()
        target = WEEKDAYS[key]
        delta = (target - current) % 7
        if delta == 0:
            delta = 7
        return (base + timedelta(days=delta)).isoformat()
    return marker


def case_reference_time(case: Dict[str, Any]) -> datetime:
    raw = case.get("reference_time") or "2026-04-17T10:00:00Z"
    return parse_dt(raw)


def parse_workspace_file(file: Dict[str, Any]) -> Dict[str, Any]:
    path = file.get("path", "")
    content = file.get("content", "")
    lines = content.splitlines()
    meta: Dict[str, Optional[str]] = {
        "path": path,
        "content": content,
        "title": None,
        "created": None,
        "modified": None,
        "summary": None,
        "artifacts": None,
        "status": None,
        "due": None,
        "time": None,
        "place": None,
        "body": "",
        "kind": "note",
    }
    body_start = 0
    for index, line in enumerate(lines[:12]):
        stripped = line.strip()
        if index == 0 and stripped.startswith("# "):
            meta["title"] = stripped[2:].strip()
            body_start = index + 1
            continue
        for key in ["created", "modified", "summary", "artifacts", "status", "due", "time", "place"]:
            prefix = key + ":"
            if stripped.startswith(prefix):
                meta[key] = stripped[len(prefix):].strip()
                body_start = index + 1
                break
    if meta["status"] is not None or path.startswith("tasks/"):
        meta["kind"] = "task"
    meta["body"] = "\n".join(lines[body_start:]).strip()
    return meta


def score_tool_calls(case: Dict[str, Any], result: Dict[str, Any]) -> CheckResult:
    check = CheckResult("tool_calls")
    actual = [call.get("name") for call in result.get("tool_calls", [])]
    expected = case.get("expect", {}).get("tool_calls", {})
    for name in expected.get("must_include", []):
        check.add(name in actual, f"tool call includes {name}")
    for name in expected.get("must_not_include", []):
        check.add(name not in actual, f"tool call excludes {name}")
    return check


def find_matching_file(files: List[Dict[str, Any]], expected: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    for file in files:
        if expected.get("exact_path") and file.get("path") != expected["exact_path"]:
            continue
        if expected.get("kind") and file.get("kind") != expected["kind"]:
            continue
        if expected.get("path_contains") and not contains_all(file.get("path", ""), expected["path_contains"]):
            continue
        if expected.get("title_contains") and not contains_all(file.get("title", ""), expected["title_contains"]):
            continue
        return file
    return None


def count_matching_files(files: List[Dict[str, Any]], expected: Dict[str, Any]) -> int:
    count = 0
    for file in files:
        if expected.get("kind") and file.get("kind") != expected["kind"]:
            continue
        if expected.get("path_contains") and not contains_all(file.get("path", ""), expected["path_contains"]):
            continue
        if expected.get("title_contains") and not contains_all(file.get("title", ""), expected["title_contains"]):
            continue
        count += 1
    return count


def score_workspace(case: Dict[str, Any], result: Dict[str, Any]) -> CheckResult:
    check = CheckResult("workspace")
    initial_paths = {f.get("path") for f in case.get("initial_workspace", {}).get("files", [])}
    files = [parse_workspace_file(f) for f in result.get("workspace", {}).get("files", [])]
    expect = case.get("expect", {})

    counts = expect.get("counts", {})
    if counts:
        note_count = sum(1 for f in files if f.get("kind") == "note")
        task_count = sum(1 for f in files if f.get("kind") == "task")
        if "notes" in counts:
            check.add(note_count == counts["notes"], f"note count == {counts['notes']} (got {note_count})")
        if "tasks" in counts:
            check.add(task_count == counts["tasks"], f"task count == {counts['tasks']} (got {task_count})")

    for expected in expect.get("files", []):
        file = find_matching_file(files, expected)
        check.add(file is not None, f"file exists for expectation {expected.get('exact_path') or expected.get('title_contains')}")
        if not file:
            continue
        check.add(file.get("title") is not None, f"file {file['path']} has title")
        check.add(file.get("created") is not None, f"file {file['path']} has created")
        check.add(file.get("modified") is not None, f"file {file['path']} has modified")
        check.add(file.get("summary") is not None, f"file {file['path']} has summary")
        check.add(file.get("artifacts") is not None, f"file {file['path']} has artifacts")

        if expected.get("summary_contains"):
            check.add(contains_all(file.get("summary", ""), expected["summary_contains"]), f"summary contains {expected['summary_contains']}")
        if expected.get("body_contains"):
            corpus = "\n".join([file.get("summary", ""), file.get("body", "")])
            check.add(contains_all(corpus, expected["body_contains"]), f"body contains {expected['body_contains']}")
        if expected.get("links_contains"):
            corpus = file.get("content", "")
            check.add(contains_all(corpus, expected["links_contains"]), f"content links contain {expected['links_contains']}")
        if expected.get("status") is not None:
            check.add(normalize_text(file.get("status")) == normalize_text(expected["status"]), f"status == {expected['status']}")
        if expected.get("due") is not None:
            due = expected["due"]
            if isinstance(due, str) and due.startswith("relative:"):
                due = resolve_relative_date(due, case_reference_time(case))
            check.add((file.get("due") or "") == due, f"due == {due}")
        if expected.get("time") is not None:
            check.add((file.get("time") or "") == expected["time"], f"time == {expected['time']}")
        if expected.get("place") is not None:
            check.add(normalize_text(file.get("place")) == normalize_text(expected["place"]), f"place == {expected['place']}")
        if expected.get("must_be_updated_existing"):
            check.add(file.get("path") in initial_paths, f"updated existing file {file.get('path')}")
        if expected.get("must_be_new"):
            check.add(file.get("path") not in initial_paths, f"created new file {file.get('path')}")
        if expected.get("must_not_duplicate"):
            dup_count = count_matching_files(files, expected)
            check.add(dup_count <= 1, f"duplicate count <= 1 (got {dup_count})")
    return check


def score_reply(case: Dict[str, Any], result: Dict[str, Any]) -> CheckResult:
    check = CheckResult("reply")
    reply = result.get("final_reply", "")
    expected = case.get("expect", {}).get("reply", {})
    for item in expected.get("must_contain", []):
        check.add(normalize_text(item) in normalize_text(reply), f"reply contains {item}")
    for item in expected.get("must_not_contain", []):
        check.add(normalize_text(item) not in normalize_text(reply), f"reply excludes {item}")
    return check


def score_case(case: Dict[str, Any], result: Dict[str, Any]) -> CaseScore:
    checks = [
        score_tool_calls(case, result),
        score_workspace(case, result),
        score_reply(case, result),
    ]
    return CaseScore(case_id=case["id"], name=case.get("name", case["id"]), checks=checks)


def print_report(scores: List[CaseScore]) -> None:
    overall_passed = sum(score.passed for score in scores)
    overall_total = sum(score.total for score in scores)
    overall_score = 0.0 if overall_total == 0 else overall_passed / overall_total
    print(f"Overall: {overall_passed}/{overall_total} ({overall_score:.1%})")
    for score in scores:
        print(f"\n[{score.case_id}] {score.name} -> {score.passed}/{score.total} ({score.score:.1%})")
        for check in score.checks:
            print(f"  - {check.name}: {check.passed}/{check.total} ({check.score:.1%})")
            for detail in check.details:
                print(f"      {detail}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("submission", help="Path to submission JSON")
    parser.add_argument("--cases-dir", default="evals/wisp_flow", help="Directory of eval case JSON files")
    args = parser.parse_args()

    cases_dir = Path(args.cases_dir)
    case_paths = sorted(p for p in cases_dir.glob("*.json") if p.name != "README.md")
    cases = [load_json(p) for p in case_paths]
    submission = load_json(Path(args.submission))
    results_by_id = {item["case_id"]: item for item in submission.get("results", [])}

    scores: List[CaseScore] = []
    for case in cases:
        result = results_by_id.get(case["id"], {"case_id": case["id"], "tool_calls": [], "final_reply": "", "workspace": {"files": []}})
        scores.append(score_case(case, result))

    print_report(scores)


if __name__ == "__main__":
    main()
