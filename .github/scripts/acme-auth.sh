#!/usr/bin/env bash
# certbot --manual-auth-hook
#
# Called once per domain (*.zefv.dev, then zefv.dev). Both use the SAME record
# name (_acme-challenge.zefv.dev) with different TXT values — add both, never
# replace. We publish the value to challenge.json on the certs branch (the app
# and GitHub web show it), then poll DNS-over-HTTPS until the value is live.
# certbot only proceeds to validation after we return, so Let's Encrypt never
# sees a premature attempt and we stay clear of the failed-validation limits.
#
# certbot env: CERTBOT_DOMAIN CERTBOT_VALIDATION CERTBOT_REMAINING_CHALLENGES CERTBOT_ALL_DOMAINS
# ours:        CERTS_WT (worktree dir of certs branch) CERTS_BRANCH WAIT_MINUTES POLL_SECONDS
set -euo pipefail

WT="${CERTS_WT:?}"; BR="${CERTS_BRANCH:-certs}"
WAIT_MINUTES="${WAIT_MINUTES:-45}"; POLL_SECONDS="${POLL_SECONDS:-20}"
NAME="_acme-challenge.${CERTBOT_DOMAIN#\*.}"
VAL="${CERTBOT_VALIDATION}"
REMAIN="${CERTBOT_REMAINING_CHALLENGES:-0}"
TOTAL=$(( $(tr ',' '\n' <<<"${CERTBOT_ALL_DOMAINS:-$CERTBOT_DOMAIN}" | wc -l) ))
STEP=$(( TOTAL - REMAIN ))

publish() {  # $1 = status
  local status="$1"
  python3 - "$WT/challenge.json" "$NAME" "$VAL" "$CERTBOT_DOMAIN" "$STEP" "$TOTAL" "$status" <<'PY'
import json, sys, datetime, os
path, name, val, dom, step, total, status = sys.argv[1:8]
now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
doc = {"records": [], "updatedAt": now}
if os.path.exists(path):
    try: doc = json.load(open(path))
    except Exception: pass
recs = [r for r in doc.get("records", []) if r.get("value") != val]
recs.append({"domain": dom, "name": name, "type": "TXT", "value": val,
             "step": int(step), "of": int(total), "status": status, "updatedAt": now})
doc["records"] = recs; doc["updatedAt"] = now
doc["instructions"] = ("Add a TXT record at %s with each pending value (keep both). "
                       "The workflow polls DNS and continues by itself once it sees them." % name)
json.dump(doc, open(path, "w"), indent=2)
PY
  ( cd "$WT" && git add challenge.json && git commit -qm "acme: $NAME step $STEP/$TOTAL $status" && git push -q origin "$BR" ) || true
}

seen_in_dns() {
  # Two independent resolvers; consider it live when either returns the value.
  local q
  for q in "https://cloudflare-dns.com/dns-query?name=${NAME}&type=TXT" \
           "https://dns.google/resolve?name=${NAME}&type=TXT"; do
    if curl -sS --max-time 10 -H 'accept: application/dns-json' "$q" 2>/dev/null | grep -Fq "$VAL"; then
      return 0
    fi
  done
  return 1
}

echo "::group::ACME DNS challenge ${STEP}/${TOTAL} for ${CERTBOT_DOMAIN}"
echo "  Record : ${NAME}  (TXT)"
echo "  Value  : ${VAL}"
[ "$REMAIN" -gt 0 ] && echo "  NOTE   : another value for the same name follows — ADD both, don't replace."
echo "::endgroup::"
echo "::notice title=Add TXT record ${STEP}/${TOTAL}::${NAME} = ${VAL}"

publish pending

DEADLINE=$(( $(date +%s) + WAIT_MINUTES * 60 ))
n=0
until seen_in_dns; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "::error::TXT ${NAME}=${VAL} not visible after ${WAIT_MINUTES} min — aborting before Let's Encrypt is asked."
    publish timeout
    exit 1
  fi
  n=$((n+1)); [ $((n % 6)) -eq 0 ] && echo "  still waiting for ${NAME} … ($(( (DEADLINE - $(date +%s)) / 60 )) min left)"
  sleep "$POLL_SECONDS"
done

echo "  ✓ ${NAME} shows the value — letting propagation settle 30s before validation."
publish seen
sleep 30
