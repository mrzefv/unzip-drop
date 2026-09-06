#!/usr/bin/env bash
# certbot --manual-cleanup-hook — mark the challenge done. TXT records can be
# deleted at leisure; they don't affect the issued cert.
set -euo pipefail
WT="${CERTS_WT:?}"; BR="${CERTS_BRANCH:-certs}"
NAME="_acme-challenge.${CERTBOT_DOMAIN#\*.}"
python3 - "$WT/challenge.json" "$CERTBOT_VALIDATION" <<'PY'
import json, sys, datetime, os
path, val = sys.argv[1:3]
if not os.path.exists(path): sys.exit(0)
doc = json.load(open(path))
now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
for r in doc.get("records", []):
    if r.get("value") == val: r["status"] = "validated"; r["updatedAt"] = now
doc["updatedAt"] = now
json.dump(doc, open(path, "w"), indent=2)
PY
( cd "$WT" && git add challenge.json && git commit -qm "acme: $NAME validated" && git push -q origin "$BR" ) || true
