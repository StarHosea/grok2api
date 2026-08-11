#!/usr/bin/env bash
# Normalize production config.yaml for public media URLs and quality-guard.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f config.yaml ]; then
  echo "missing config.yaml in $(pwd)" >&2
  exit 1
fi

PUBLIC_API_BASE_URL="${GROK2API_PUBLIC_API_BASE_URL:-https://grok2api.shuangdeng.space}"

python3 - "$PUBLIC_API_BASE_URL" <<'PY'
from pathlib import Path
import sys

public_url = sys.argv[1].rstrip("/")
path = Path("config.yaml")
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

quality_block = """
qualityGuard:
  enabled: true
  model: "grok-4.5"
  mode: hybrid
  activeInterval: 30m
  passivePollInterval: 5s
  softTPS: 500
  hardTPS: 1000
  consecutiveSoft: 2
  consecutiveErrors: 2
  quarantineDuration: 5m
  noAccountBackoff: 5m
  minimumHealthyNodes: 1
  maxOutputTokens: 384
  failClosed: false
  minimumGenerationWindow: 1s
  rotationURL: ""
  rotationToken: ""
  rotationTimeout: 45s
  nodeIDs: []
  rotatableNodeIDs: []
""".strip("\n")

# --- frontend.publicApiBaseURL ---
out = []
in_frontend = False
saw_frontend = False
has_public = False
for line in lines:
    stripped = line.lstrip()
    indent = line[: len(line) - len(stripped)]
    if line.startswith("frontend:"):
        in_frontend = True
        saw_frontend = True
        out.append(line)
        continue
    if in_frontend and stripped and not line.startswith((" ", "\t")) and not stripped.startswith("#"):
        if not has_public:
            out.append(f"  publicApiBaseURL: \"{public_url}\"")
            has_public = True
        in_frontend = False
    if in_frontend and stripped.startswith("publicApiBaseURL:"):
        out.append(f"{indent}publicApiBaseURL: \"{public_url}\"")
        has_public = True
        continue
    out.append(line)
if in_frontend and not has_public:
    out.append(f"  publicApiBaseURL: \"{public_url}\"")
    has_public = True
if not saw_frontend:
    out.extend(["", "frontend:", f"  publicApiBaseURL: \"{public_url}\"", '  staticPath: "./frontend/dist"'])

text = "\n".join(out)

# --- qualityGuard ---
if "qualityGuard:" not in text:
    text = text.rstrip() + "\n\n" + quality_block + "\n"
else:
    lines = text.splitlines()
    out = []
    in_qg = False
    replaced_enabled = False
    replaced_min = False
    for line in lines:
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        if line.startswith("qualityGuard:"):
            in_qg = True
            out.append(line)
            continue
        if in_qg and stripped and not line.startswith((" ", "\t")) and not stripped.startswith("#"):
            in_qg = False
        if in_qg and stripped.startswith("enabled:"):
            out.append(f"{indent}enabled: true")
            replaced_enabled = True
            continue
        if in_qg and stripped.startswith("minimumHealthyNodes:"):
            out.append(f"{indent}minimumHealthyNodes: 1")
            replaced_min = True
            continue
        out.append(line)
    if not replaced_enabled:
        raise SystemExit("qualityGuard.enabled not found in config.yaml")
    if not replaced_min:
        patched = []
        inserted = False
        for line in out:
            patched.append(line)
            if (not inserted) and line.lstrip().startswith("enabled:"):
                indent = line[: len(line) - len(line.lstrip())]
                patched.append(f"{indent}minimumHealthyNodes: 1")
                inserted = True
        if not inserted:
            raise SystemExit("failed to insert qualityGuard.minimumHealthyNodes")
        out = patched
    text = "\n".join(out) + "\n"

path.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")
print(f"[deploy] frontend.publicApiBaseURL={public_url}")
print("[deploy] qualityGuard enabled in config.yaml")
PY

chmod 600 config.yaml
