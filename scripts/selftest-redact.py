#!/usr/bin/env python3
"""selftest-redact.py — prove lib/redact.py masks what it claims and nothing else.

Fake credentials are assembled at run time from pieces: written out whole they
would look like real leaks to GitHub secret scanning (and push protection would
reject the commit).
"""
import os
import random
import string
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from redact import redact  # noqa: E402

rng = random.Random(7)


def rand(n, alphabet=string.ascii_letters + string.digits):
    return "".join(rng.choice(alphabet) for _ in range(n))


HEX = "0123456789abcdef"
UPPER = string.ascii_uppercase + string.digits

MUST_MASK = {
    "anthropic": "sk-" + "ant-api03-" + rand(80),
    "openai": "sk-" + "proj-" + rand(48),
    "openai (legacy)": "sk-" + rand(48),
    "github classic": "gh" + "p_" + rand(36),
    "github oauth": "gh" + "o_" + rand(36),
    "github fine-grained": "github" + "_pat_" + rand(82, string.ascii_letters + string.digits + "_"),
    "gitlab": "glp" + "at-" + rand(20),
    "aws": "AK" + "IA" + rand(16, UPPER),
    "google": "AI" + "za" + rand(35),
    "slack": "xo" + "xb-" + rand(12, string.digits) + "-" + rand(24),
    "digitalocean": "do" + "p_v1_" + rand(64, HEX),
    "stripe": "sk" + "_live_" + rand(24),
    "jwt": "ey" + "J" + rand(20) + ".ey" + "J" + rand(30) + "." + rand(40),
    "private key": "-----BEGIN RSA " + "PRIVATE KEY-----\n" + rand(64) + "\n-----END RSA " + "PRIVATE KEY-----",
}

MUST_KEEP = [
    "Usa sk-learn para el modelo y el flag --task-id.",
    "El commit 9d61be3f0c2a4e1b8d7c6a5f4e3d2c1b0a9f8e7d arregla el lock.",
    "uuid 70a46490-ca3c-470d-9458-55b23e0bab61 de la sesión",
    "/home/alice/Code/risk-assessment/sk-module/main.py",
    "La clave empieza por sk- y no la pego aquí.",
    "ghp_ es el prefijo de los tokens clásicos de GitHub",
    "Bearer y eyJ son pistas, no un token completo.",
    "rama sk-learn-model-training-pipeline-v2-final-review",
]

failed = 0
for kind, secret in MUST_MASK.items():
    text = f"antes {secret} después"
    out = redact(text)
    ok = secret not in out and "[REDACTED:" in out and out.startswith("antes ") and out.endswith(" después")
    print(f"  {'ok  ' if ok else 'FAIL'} — masks {kind}")
    failed += not ok

for text in MUST_KEEP:
    ok = redact(text) == text
    print(f"  {'ok  ' if ok else 'FAIL'} — keeps: {text[:50]}")
    failed += not ok

# Redacting a JSONL line must keep it valid JSON (the curator reads a redacted copy).
import json  # noqa: E402
line = json.dumps({"message": {"role": "user", "content": "token " + MUST_MASK["github classic"]}})
try:
    json.loads(redact(line))
    print("  ok   — a redacted JSONL line is still valid JSON")
except ValueError:
    print("  FAIL — a redacted JSONL line is no longer valid JSON")
    failed += 1

total = len(MUST_MASK) + len(MUST_KEEP) + 1
print(f"\nselftest-redact: {total - failed} passed, {failed} failed")
sys.exit(1 if failed else 0)
