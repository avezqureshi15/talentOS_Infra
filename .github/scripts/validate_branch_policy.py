#!/usr/bin/env python3
"""Validate branches against per-env allowlists in scripts/branch-policy.json.

Empty list / missing env key = any branch allowed (permissive default).
Fill the JSON to restrict, e.g. {"prod": {"fe": ["main", "release/*"]}}.
Wildcards use fnmatch syntax.
"""
import argparse
import fnmatch
import json
import pathlib
import sys

REPOS = ("be", "fe", "ai", "mcp", "rh")


def load_env_defaults(env_name: str) -> dict:
    env_file = pathlib.Path("scripts") / f"branches.{env_name}.env"
    defaults = {}
    if env_file.exists():
        for line in env_file.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    defaults[key] = value
    return defaults


def _load_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("env")
    for repo in REPOS:
        parser.add_argument(f"--{repo}-branch", default="")
    args = parser.parse_args()

    policy_path = pathlib.Path("scripts") / "branch-policy.json"
    policy = json.loads(_load_text(policy_path))
    env_policy = policy.get(args.env, {})
    resolved = {r: getattr(args, f"{r}_branch") for r in REPOS}

    violations = []
    for repo, branch in resolved.items():
        if not branch:
            continue
        allowed = env_policy.get(repo) or []
        if not allowed:
            continue
        if not any(fnmatch.fnmatch(branch, pattern) for pattern in allowed):
            violations.append(
                f"  {repo}: '{branch}' not allowed in env '{args.env}' "
                f"(allowed: {', '.join(allowed) or 'any'})"
            )

    if violations:
        print("Branch policy violation:")
        print("\n".join(violations))
        return 1

    print(
        f"Branch policy OK for env '{args.env}' "
        f"(be={resolved['be']}, fe={resolved['fe']}, ai={resolved['ai']}, mcp={resolved['mcp']}, rh={resolved['rh']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
