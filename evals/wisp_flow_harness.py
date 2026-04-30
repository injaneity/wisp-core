#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional


def load_json(path: Path) -> Any:
    with path.open() as f:
        return json.load(f)


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def default_schema_content() -> str:
    return """# Tag Guide

Use section tags in headings, not file-level metadata.
Prefer short namespaced tags such as:
- #person/sean
- #project/wisp
- #topic/oauth
- #task/followup
"""


def render_workspace_config(
    repo_root: Path,
    wiki_root: Path,
    provider: Optional[str],
    base_url: Optional[str],
    model: Optional[str],
    reasoning_effort: Optional[str],
    api_key_env: Optional[str],
) -> str:
    local_providers = {"ollama", "lmstudio", "lm-studio", "llamacpp", "llama.cpp"}
    default_model = "gemma4" if (provider or "").lower() in local_providers else "gpt-5.4"
    lines = [
        "# Wisp workspace configuration",
        "paths:",
        f'  repo_root: "{repo_root}"',
        f'  wiki_root: "{wiki_root}"',
        "model:",
        f'  provider: "{provider or "codex"}"',
        f'  name: "{model or default_model}"',
        f'  reasoning_effort: "{reasoning_effort or "medium"}"',
    ]
    if base_url:
        lines.append(f'  base_url: "{base_url}"')
    if api_key_env:
        lines.append(f'  api_key_env: "{api_key_env}"')
    return "\n".join(lines) + "\n"


def materialize_workspace(
    case: Dict[str, Any],
    root: Path,
    repo_root: Path,
    provider: Optional[str],
    base_url: Optional[str],
    model: Optional[str],
    reasoning_effort: Optional[str],
    api_key_env: Optional[str],
) -> Dict[str, Path]:
    work_dir = root / "work"
    wiki_dir = root / "wiki"
    config_path = work_dir / ".wisp" / "config.yaml"
    wiki_dir.mkdir(parents=True, exist_ok=True)
    write_text(config_path, render_workspace_config(repo_root, wiki_dir, provider, base_url, model, reasoning_effort, api_key_env))

    schema_path = wiki_dir / "schema.md"
    if not schema_path.exists():
        write_text(schema_path, default_schema_content())

    for file in case.get("initial_workspace", {}).get("files", []):
        rel_path = file["path"]
        write_text(wiki_dir / rel_path, file["content"])

    return {
        "work_dir": work_dir,
        "wiki_dir": wiki_dir,
        "session_log": wiki_dir / ".wisp" / "session.jsonl",
    }


def run_wisp(wisp_bin: Path, work_dir: Path, capture: str, timeout: int) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    return subprocess.run(
        [str(wisp_bin)],
        input=capture + "\n",
        cwd=work_dir,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def parse_session_log(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    events = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def collect_workspace_files(wiki_dir: Path) -> List[Dict[str, str]]:
    files: List[Dict[str, str]] = []
    for path in sorted(wiki_dir.rglob("*.md")):
        rel = path.relative_to(wiki_dir).as_posix()
        if rel == "schema.md":
            continue
        if rel.startswith(".wisp/"):
            continue
        files.append({
            "path": rel,
            "content": path.read_text(),
        })
    return files


def extract_tool_calls(events: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    calls = []
    for event in events:
        if event.get("type") != "tool_call":
            continue
        payload = event.get("payload", {})
        calls.append({
            "name": payload.get("name", ""),
            "arguments": payload.get("arguments", ""),
            "call_id": payload.get("call_id", ""),
        })
    return calls


def extract_final_reply(events: List[Dict[str, Any]], stdout: str) -> str:
    messages = []
    for event in events:
        if event.get("type") == "model_response":
            payload = event.get("payload", {})
            message = (payload.get("message") or "").strip()
            if message:
                messages.append(message)
    if messages:
        return messages[-1]

    lines = [line for line in stdout.splitlines() if line.startswith("assistant> ")]
    if not lines:
        return ""
    return lines[-1].removeprefix("assistant> ").strip()


def build_case_result(case: Dict[str, Any], completed: subprocess.CompletedProcess[str], files: List[Dict[str, str]], events: List[Dict[str, Any]]) -> Dict[str, Any]:
    result = {
        "case_id": case["id"],
        "tool_calls": extract_tool_calls(events),
        "final_reply": extract_final_reply(events, completed.stdout),
        "workspace": {"files": files},
    }
    if completed.returncode != 0:
        result["process_error"] = completed.stderr.strip() or completed.stdout.strip()
    return result


def run_case(
    case: Dict[str, Any],
    wisp_bin: Path,
    repo_root: Path,
    provider: Optional[str],
    base_url: Optional[str],
    model: Optional[str],
    reasoning_effort: Optional[str],
    api_key_env: Optional[str],
    timeout: int,
    keep_temp: bool,
) -> Dict[str, Any]:
    tmp_root = Path(tempfile.mkdtemp(prefix=f"wisp-eval-{case['id']}-"))
    try:
        paths = materialize_workspace(case, tmp_root, repo_root, provider, base_url, model, reasoning_effort, api_key_env)
        completed = run_wisp(wisp_bin, paths["work_dir"], case.get("input", {}).get("capture", ""), timeout)
        events = parse_session_log(paths["session_log"])
        files = collect_workspace_files(paths["wiki_dir"])
        result = build_case_result(case, completed, files, events)
        if keep_temp:
            result["temp_dir"] = str(tmp_root)
        return result
    finally:
        if not keep_temp:
            shutil.rmtree(tmp_root, ignore_errors=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases-dir", default="evals/wisp_flow", help="Directory containing eval case JSON files")
    parser.add_argument("--out", default="evals/runs/wisp_flow_submission.json", help="Where to write submission JSON")
    parser.add_argument("--wisp-bin", default=".build/debug/wisp", help="Path to built wisp binary")
    parser.add_argument("--repo-root", default=".", help="Repo root to embed in generated config")
    parser.add_argument("--base-url", default=None, help="Override model base_url in generated config")
    parser.add_argument("--provider", default=None, help="Override model provider in generated config")
    parser.add_argument("--model", default=None, help="Override model name in generated config")
    parser.add_argument("--reasoning-effort", default=None, help="Override reasoning effort in generated config")
    parser.add_argument("--api-key-env", default=None, help="Environment variable name for OpenAI-compatible API bearer auth")
    parser.add_argument("--timeout", type=int, default=180, help="Per-case timeout in seconds")
    parser.add_argument("--case", action="append", default=[], help="Run only matching case id(s)")
    parser.add_argument("--keep-temp", action="store_true", help="Keep temporary workspaces for inspection")
    args = parser.parse_args()

    cases_dir = Path(args.cases_dir)
    case_paths = sorted(p for p in cases_dir.glob("*.json") if p.name != "README.md")
    cases = [load_json(path) for path in case_paths]
    if args.case:
        wanted = set(args.case)
        cases = [case for case in cases if case["id"] in wanted]

    wisp_bin = Path(args.wisp_bin).resolve()
    repo_root = Path(args.repo_root).resolve()

    results = []
    for case in cases:
        print(f"Running {case['id']}...", file=sys.stderr)
        results.append(
            run_case(
                case,
                wisp_bin,
                repo_root,
                args.provider,
                args.base_url,
                args.model,
                args.reasoning_effort,
                args.api_key_env,
                args.timeout,
                args.keep_temp,
            )
        )

    output = {"results": results}
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, indent=2))
    print(out_path)


if __name__ == "__main__":
    main()
