#!/usr/bin/env python3
"""Reject likely plaintext interpolation inside IMELog calls.

This tiny Swift string/call scanner follows multiline calls, nested
interpolation and raw strings. It makes the common privacy regression
`IMELog.write("text=\\(text)")` fail while allowing explicit redaction or
aggregate-only properties such as `.count`.
"""

from __future__ import annotations

import pathlib
import re
import sys
from dataclasses import dataclass


CALL = re.compile(r"IMELog\.(?:write|reset)\s*\(")
SENSITIVE = re.compile(
    r"(?<![A-Za-z0-9_])"
    r"(text|commit|raw|preedit|input|candidate|candidateText|message|body|"
    r"content|clean|payload|response|value|output|draft|fragment|delta|data)"
    r"(?![A-Za-z0-9_])"
)
SAFE_AGGREGATES = (".count", ".isEmpty", ".utf8.count")


@dataclass(frozen=True)
class Interpolation:
    offset: int
    expression: str


def string_start(source: str, index: int) -> tuple[int, bool] | None:
    cursor = index
    while cursor < len(source) and source[cursor] == "#":
        cursor += 1
    hashes = cursor - index
    if source.startswith('"""', cursor):
        return hashes, True
    if cursor < len(source) and source[cursor] == '"':
        return hashes, False
    return None


def skip_string(source: str, index: int, hashes: int, triple: bool) \
        -> tuple[int, list[Interpolation]]:
    quote = '"""' if triple else '"'
    cursor = index + hashes + len(quote)
    closing = quote + ("#" * hashes)
    interpolation_prefix = "\\" + ("#" * hashes) + "("
    values: list[Interpolation] = []
    while cursor < len(source):
        if source.startswith(closing, cursor):
            return cursor + len(closing), values
        if source.startswith(interpolation_prefix, cursor):
            end, expression = read_interpolation(
                source, cursor + len(interpolation_prefix)
            )
            values.append(Interpolation(cursor, expression))
            cursor = end
            continue
        if hashes == 0 and not triple and source[cursor] == "\\":
            cursor += 2
        else:
            cursor += 1
    return len(source), values


def read_interpolation(source: str, index: int) -> tuple[int, str]:
    start = index
    depth = 1
    cursor = index
    while cursor < len(source):
        nested_string = string_start(source, cursor)
        if nested_string is not None:
            cursor, _ = skip_string(source, cursor, *nested_string)
            continue
        if source[cursor] == "(":
            depth += 1
        elif source[cursor] == ")":
            depth -= 1
            if depth == 0:
                return cursor + 1, source[start:cursor]
        cursor += 1
    return len(source), source[start:]


def call_interpolations(source: str, opening_parenthesis: int) \
        -> list[Interpolation]:
    cursor = opening_parenthesis + 1
    depth = 1
    values: list[Interpolation] = []
    while cursor < len(source) and depth:
        if source.startswith("//", cursor):
            newline = source.find("\n", cursor)
            if newline < 0:
                break
            cursor = newline + 1
            continue
        if source.startswith("/*", cursor):
            end = source.find("*/", cursor + 2)
            cursor = len(source) if end < 0 else end + 2
            continue
        nested_string = string_start(source, cursor)
        if nested_string is not None:
            cursor, found = skip_string(source, cursor, *nested_string)
            values.extend(found)
            continue
        if source[cursor] == "(":
            depth += 1
        elif source[cursor] == ")":
            depth -= 1
        cursor += 1
    return values


def unsafe_reason(expression: str) -> str | None:
    stripped = expression.strip()
    for token in SENSITIVE.finditer(expression):
        tail = expression[token.end():].lstrip()
        if stripped.startswith("IMELog.redact(") and stripped.endswith(")"):
            continue
        if tail.startswith(SAFE_AGGREGATES):
            continue
        # BufferDeliveryReason.message is enum-owned fixed text, not input.
        if token.group(1) == "message" and stripped == "reason.message":
            continue
        return f"unsafe `{token.group(1)}` in \\({stripped}\\)"
    return None


def lint_source(source: str, label: str) -> list[str]:
    failures: list[str] = []
    for call in CALL.finditer(source):
        for interpolation in call_interpolations(source, call.end() - 1):
            line = source.count("\n", 0, interpolation.offset) + 1
            if interpolation.offset > 0 and source[interpolation.offset - 1] == "'":
                failures.append(
                    f"{label}:{line}: quoted interpolation in IMELog; redact it"
                )
            reason = unsafe_reason(interpolation.expression)
            if reason:
                failures.append(f"{label}:{line}: {reason}")
    return failures


def self_test() -> None:
    unsafe = [
        'IMELog.write("text=\\(text)")',
        'IMELog.write(\n  "payload=\\(payload)"\n)',
        'IMELog.write(#"raw=\\#(raw)"#)',
        'IMELog.write("value \'\\(safeID)\'")',
    ]
    safe = [
        'IMELog.write("text=\\(IMELog.redact(text))")',
        'IMELog.write("chars=\\(text.count)")',
        'IMELog.write("reason=\\(reason.message)")',
    ]
    assert all(lint_source(value, "self-test") for value in unsafe)
    assert all(not lint_source(value, "self-test") for value in safe)


def main() -> int:
    self_test()
    failures: list[str] = []
    for path in pathlib.Path("Sources").rglob("*.swift"):
        failures.extend(lint_source(path.read_text(encoding="utf-8"), str(path)))
    if failures:
        print("IMELog privacy lint failed:")
        print("\n".join(failures))
        return 1
    print("IMELog privacy lint: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
