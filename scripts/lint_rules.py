#!/usr/bin/env python3
"""Automated quality gate for AdGuardHome.yaml, built-in rules, and noads paths."""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
AGH_ROOT = ROOT / "Adguardhome"
YAML_PATH = AGH_ROOT / "bin" / "AdGuardHome.yaml"
BUILTIN_RULES = AGH_ROOT / "bin" / "data" / "userfilters" / "builtin_rules.txt"
NOADS_LIST = AGH_ROOT / "scripts" / "noads_paths.list"
UPDATE_JSON = ROOT / "Update.json"

ALLOWED_MODIFIERS = {"important", "dnstype", "dnsrewrite", "ctag", "client", "badfilter"}
DISALLOWED_OVERBROAD = {
    "||ad.*^$important",
    "||ads.*^$important",
    "||log.*^$important",
    "||analytics.*^$important",
    "||leads.*^$important",
    "||abtest.*^$important",
    "@@||*push.*^$important",
    "@@||quark.*^$important",
}
DISALLOWED_PATHS = (
    "/data/system/ifw",
    "/data/data/com.galaxy.stock/files",
)


def check_yaml(errors: list[str]) -> None:
    text = YAML_PATH.read_text(encoding="utf-8")
    if "ghfast.top" in text:
        errors.append(f"{YAML_PATH}: contains third-party proxy URL ghfast.top")
    if "$2a$10$zHcQbG4nXIzPB/Cj5M9lQ.qbQH/EZAT2wakz/sK1.b/d4ey2oqUd2" in text:
        errors.append(f"{YAML_PATH}: still contains hardcoded upstream root/root bcrypt hash")
    if re.search(r"(?m)^  edns_client_subnet:\n(?:    .*\n)*?    enabled:\s*true\b", text):
        errors.append(f"{YAML_PATH}: edns_client_subnet.enabled should default to false")
    if "log_blocked_only: true" not in text:
        errors.append(f"{YAML_PATH}: sni_filter.log_blocked_only should default to true")
    if "anonymize_client_ip: true" not in text:
        errors.append(f"{YAML_PATH}: dns.anonymize_client_ip should default to true")

    upd = UPDATE_JSON.read_text(encoding="utf-8")
    if "ghfast.top" in upd:
        errors.append(f"{UPDATE_JSON}: contains third-party proxy URL ghfast.top")


def check_rules(errors: list[str]) -> None:
    if not BUILTIN_RULES.exists():
        errors.append(f"Missing {BUILTIN_RULES}")
        return

    seen: dict[str, int] = {}
    blocked: dict[str, int] = {}
    allowed: dict[str, int] = {}

    for lineno, raw in enumerate(BUILTIN_RULES.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("!") or line.startswith("#"):
            continue

        if line in seen:
            errors.append(f"{BUILTIN_RULES}:{lineno}: duplicate rule {line!r} (first at line {seen[line]})")
        seen[line] = lineno

        if line in DISALLOWED_OVERBROAD:
            errors.append(f"{BUILTIN_RULES}:{lineno}: overly broad wildcard rule {line!r}")

        if not (line.startswith("||") or line.startswith("@@||")):
            errors.append(f"{BUILTIN_RULES}:{lineno}: rule missing || prefix: {line!r}")

        if "^" not in line:
            errors.append(f"{BUILTIN_RULES}:{lineno}: rule missing ^ separator: {line!r}")

        if re.search(r"\^[^$]", line):
            errors.append(f"{BUILTIN_RULES}:{lineno}: missing '$' before modifier: {line!r}")

        if "$" in line:
            mods = line.split("$", 1)[1].split(",")
            for mod in mods:
                key = mod.split("=", 1)[0].lstrip("~")
                if key not in ALLOWED_MODIFIERS:
                    errors.append(f"{BUILTIN_RULES}:{lineno}: unknown/typo modifier {mod!r} in {line!r}")

        if re.search(r"\|\|\d+\.\d+\.\d+\.\d+", line):
            errors.append(f"{BUILTIN_RULES}:{lineno}: IP/CIDR rule ineffective in DNS/SNI filter: {line!r}")

        dom = re.sub(r"^(@@)?\|\|", "", line).split("^", 1)[0].split("$", 1)[0]
        if line.startswith("@@"):
            allowed[dom] = lineno
        else:
            blocked[dom] = lineno

    for dom in sorted(set(blocked) & set(allowed)):
        errors.append(
            f"{BUILTIN_RULES}: conflicting block (line {blocked[dom]}) and allow (line {allowed[dom]}) for {dom!r}"
        )


def check_noads(errors: list[str]) -> None:
    if not NOADS_LIST.exists():
        errors.append(f"Missing {NOADS_LIST}")
        return

    for lineno, raw in enumerate(NOADS_LIST.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("/data/"):
            errors.append(f"{NOADS_LIST}:{lineno}: path must be absolute under /data/: {line!r}")
        if ".." in line:
            errors.append(f"{NOADS_LIST}:{lineno}: path traversal not allowed: {line!r}")
        for bad in DISALLOWED_PATHS:
            if line == bad or line.startswith(bad + "/"):
                errors.append(f"{NOADS_LIST}:{lineno}: disallowed destructive path {line!r}")


def main() -> int:
    errors: list[str] = []
    check_yaml(errors)
    check_rules(errors)
    check_noads(errors)

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    print("All YAML, rule, and noads checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
