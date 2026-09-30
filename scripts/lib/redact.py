#!/usr/bin/env python3
"""Mask well-known credential formats before session text reaches the vault.

The vault is synced to the cloud, so a token pasted in a chat would otherwise
travel there verbatim. Detection is by PROVIDER PREFIX and exact shape only:
a generic "looks like a secret" heuristic (long random-ish strings, anything
after "key=") was tried elsewhere and flagged prose 26 times out of 26. A
missed exotic format is the accepted trade-off for never corrupting notes.

Usable as a module (`from redact import redact`) or as a filter:
    python3 redact.py < in > out
"""
import re
import sys

PATTERNS = [
    ("private-key", re.compile(
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
        re.DOTALL)),
    ("anthropic", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}")),
    # Legacy keys are plain alphanumerics; only the prefixed kinds carry - and _.
    # Allowing hyphens without a prefix matched long slugs like "sk-learn-...".
    ("openai", re.compile(r"\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{32,}")),
    ("openai", re.compile(r"\bsk-[A-Za-z0-9]{32,}\b")),
    ("github", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}")),
    ("github", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{50,}")),
    ("gitlab", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}")),
    ("aws", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("google", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("slack", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("digitalocean", re.compile(r"\bdo[por]_v1_[a-f0-9]{64}")),
    ("stripe", re.compile(r"\b[rs]k_(?:live|test)_[A-Za-z0-9]{24,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
]


def redact(text):
    """Return text with every known credential replaced by [REDACTED:<kind>]."""
    if not text:
        return text
    for kind, pattern in PATTERNS:
        text = pattern.sub(f"[REDACTED:{kind}]", text)
    return text


if __name__ == "__main__":
    sys.stdout.write(redact(sys.stdin.read()))
