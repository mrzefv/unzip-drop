#!/usr/bin/env bash
# certbot --manual-auth-hook
#
# Called once per domain (*.example.com, then example.com). Both use the SAME
# record name (_acme-challenge.example.com) with different TXT values — add
# both, never replace. We publish the value to challenge.json on the certs
# branch (the app shows it), then wait until the record is really there.
#
# How we check (in order, every POLL_SECONDS):
#   1. AUTHORITATIVE — dig the zone's own NS servers directly. Never cached,
#      so this flips the moment your DNS host saves the record. This is the
#      check that gates certbot.
#   2. Public resolvers (Cloudflare / Google / Quad9 DoH) — informational only;
#      these can hold a cached NXDOMAIN for minutes after you add the record.
#   3. FORCE — the app can set "force": true on the record in challenge.json;
#      we pull the file each loop and continue immediately if it's set.
#
# Every loop writes what it saw into challenge.json ("lastCheck") so the app
# can show authoritative vs cached state instead of a bare "waiting".
#
# certbot env: CERTBOT_DOMAIN CERTBOT_VALIDATION CERTBOT_REMAINING_CHALLENGES CERTBOT_ALL_DOMAINS
# ours:        CERTS_WT CERTS_BRANCH WAIT_MINUTES POLL_SECONDS
set -euo pipefail

WT="${CERTS_WT:?}"; BR="${CERTS_BRANCH:-certs}"
WAIT_MINUTES="${WAIT_MINUTES:-45}"; POLL_SECONDS="${POLL_SECONDS:-20}"
ZONE="${CERTBOT_DOMAIN#\*.}"
NAME="_acme-challenge.${ZONE}"
VAL="${CERTBOT_VALIDATION}"
REMAIN="${CERTBOT_REMAINING_CHALLENGES:-0}"
TOTAL=$(( $(tr ',' '\n' <<<"${CERTBOT_ALL_DOMAINS:-$CERTBOT_DOMAIN}" | wc -l) ))
STEP=$(( TOTAL - REMAIN ))

# ---------------------------------------------------------------- helpers
sync_branch() { ( cd "$WT" && git fetch -q origin "$BR" && git reset -q --hard "origin/$BR" ) || true; }

publish() {  # $1=status  $2=json object with check details (or "{}")
  python3 - "$WT/challenge.json" "$NAME" "$VAL" "$CERTBOT_DOMAIN" "$STEP" "$TOTAL" "$1" "${2:-{}}" <<'PY'
import json, sys, datetime, os
path, name, val, dom, step, total, status, check = sys.argv[1:9]
now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
doc = {"records": [], "updatedAt": now}
if os.path.exists(path):
    try: doc = json.load(open(path))
    except Exception: pass
recs = doc.get("records", [])
existing = next((r for r in recs if r.get("value") == val), None)
force = bool(existing.get("force")) if existing else False
recs = [r for r in recs if r.get("value") != val]
rec = {"domain": dom, "name": name, "type": "TXT", "value": val,
       "step": int(step), "of": int(total), "status": status, "force": force, "updatedAt": now}
try: rec["lastCheck"] = json.loads(check)
except Exception: rec["lastCheck"] = {}
recs.append(rec)
doc["records"] = recs; doc["updatedAt"] = now
doc["instructions"] = ("Add a TXT record at %s with each pending value (keep both). "
                       "Gate = the zone's authoritative nameservers; public resolvers may lag. "
                       "Use Force continue in the app if you're sure the record is saved." % name)
json.dump(doc, open(path, "w"), indent=2)
PY
  ( cd "$WT" && git add challenge.json && git commit -qm "acme: $NAME step $STEP/$TOTAL $1" && git push -q origin "$BR" ) \
    || { sync_branch; ( cd "$WT" && git add challenge.json && git commit -qm "acme: $NAME step $STEP/$TOTAL $1" && git push -q origin "$BR" ) || true; }
}

forced() {
  sync_branch
  python3 - "$WT/challenge.json" "$VAL" <<'PY'
import json, sys, os
path, val = sys.argv[1:3]
if not os.path.exists(path): sys.exit(1)
doc = json.load(open(path))
sys.exit(0 if any(r.get("value") == val and r.get("force") for r in doc.get("records", [])) else 1)
PY
}

# Authoritative NS list for the zone (walk up if the zone is a subdomain).
find_ns() {
  local z="$1"
  while [ -n "$z" ]; do
    local ns; ns=$(dig +short NS "$z" @1.1.1.1 2>/dev/null | sed 's/\.$//' | sort -u | tr '\n' ' ')
    [ -n "$ns" ] && { echo "$ns"; return 0; }
    z="${z#*.}"; [[ "$z" == *.* ]] || break
  done
  return 1
}

auth_txt() {  # prints TXT values seen at each NS; returns 0 if VAL present at any
  local ok=1 ns
  AUTH_JSON="{"
  for ns in $NS_LIST; do
    local got; got=$(dig +short +time=4 +tries=1 TXT "$NAME" "@$ns" 2>/dev/null | tr -d '"' | tr '\n' '|' | sed 's/|$//')
    local hit=false; grep -Fq "$VAL" <<<"$got" && { hit=true; ok=0; }
    AUTH_JSON="${AUTH_JSON}\"$ns\":{\"seen\":$hit,\"txt\":\"${got//\"/}\"},"
  done
  AUTH_JSON="${AUTH_JSON%,}}"
  return $ok
}

doh_seen() {  # $1=url  → true/false
  curl -sS --max-time 8 -H 'accept: application/dns-json' "$1" 2>/dev/null | grep -Fq "$VAL" && echo true || echo false
}

check_json() {  # assemble lastCheck
  local cf gg q9 now
  cf=$(doh_seen "https://cloudflare-dns.com/dns-query?name=${NAME}&type=TXT")
  gg=$(doh_seen "https://dns.google/resolve?name=${NAME}&type=TXT")
  q9=$(doh_seen "https://dns.quad9.net:5053/dns-query?name=${NAME}&type=TXT")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"at\":\"$now\",\"authoritative\":${AUTH_JSON:-{}},\"authoritativeSeen\":${AUTH_OK:-false},\"resolvers\":{\"cloudflare\":$cf,\"google\":$gg,\"quad9\":$q9}}"
}

# ---------------------------------------------------------------- go
echo "::group::ACME DNS challenge ${STEP}/${TOTAL} for ${CERTBOT_DOMAIN}"
echo "  Record : ${NAME}  (TXT)"
echo "  Value  : ${VAL}"
[ "$REMAIN" -gt 0 ] && echo "  NOTE   : another value for the same name follows — ADD both, don't replace."
echo "::endgroup::"
echo "::notice title=Add TXT record ${STEP}/${TOTAL}::${NAME} = ${VAL}"

NS_LIST=$(find_ns "$ZONE" || true)
if [ -z "$NS_LIST" ]; then
  echo "::warning::couldn't find authoritative NS for $ZONE — falling back to public resolvers"
else
  echo "  Authoritative NS: $NS_LIST"
fi

AUTH_OK=false
publish pending "$(check_json)"

DEADLINE=$(( $(date +%s) + WAIT_MINUTES * 60 ))
n=0
while :; do
  # 1. authoritative (gate)
  if [ -n "$NS_LIST" ] && auth_txt; then AUTH_OK=true; echo "  ✓ authoritative NS return the value"; publish seen "$(check_json)"; break; fi
  AUTH_OK=false
  # 2. no NS list → accept any public resolver
  if [ -z "$NS_LIST" ]; then
    cj=$(check_json)
    if grep -q '"cloudflare":true\|"google":true\|"quad9":true' <<<"$cj"; then echo "  ✓ public resolver returns the value"; publish seen "$cj"; break; fi
  fi
  # 3. force from the app
  if forced; then echo "  ▶ force continue set from the app — proceeding"; publish forced "$(check_json)"; break; fi

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "::error::TXT ${NAME}=${VAL} never appeared at the authoritative NS after ${WAIT_MINUTES} min — aborting before Let's Encrypt is asked."
    publish timeout "$(check_json)"; exit 1
  fi
  n=$((n+1))
  if [ $((n % 3)) -eq 0 ]; then publish pending "$(check_json)"; fi   # refresh diagnostics every ~1 min
  [ $((n % 6)) -eq 0 ] && echo "  still waiting for ${NAME} … ($(( (DEADLINE - $(date +%s)) / 60 )) min left)"
  sleep "$POLL_SECONDS"
done

# Let's Encrypt validates from many vantage points; give secondaries a moment.
sleep 20
