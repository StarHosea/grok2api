#!/usr/bin/env bash
# Ensure production config.yaml has qualityGuard enabled for the single-node fleet.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f config.yaml ]; then
  echo "missing config.yaml in $(pwd)" >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path

path = Path("config.yaml")
text = path.read_text(encoding="utf-8")
block = """
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

if "qualityGuard:" not in text:
    path.write_text(text.rstrip() + "\n\n" + block + "\n", encoding="utf-8")
    raise SystemExit(0)

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
    # Older configs may omit the field; insert after enabled.
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

path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY

chmod 600 config.yaml
echo "[deploy] qualityGuard enabled in config.yaml"
