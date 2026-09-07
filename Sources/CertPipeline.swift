//
//  CertPipeline.swift
//  The certbot pipeline files, embedded so the app can install them into any
//  repo with one tap (Settings › OTA Domain › Link repo / Update pipeline).
//  Byte-for-byte the copies under .github/. Regenerated from the fixed
//  certs.yml (email/ca inputs, rebase-retry publish, glob live-dir).
//

import Foundation

nonisolated enum CertPipeline {
    static let branch = "certs"

    static var files: [(path: String, data: Data)] {
        [
            (".github/workflows/certs.yml",      Data(certsYML.utf8)),
            (".github/scripts/acme-auth.sh",     Data(acmeAuth.utf8)),
            (".github/scripts/acme-cleanup.sh",  Data(acmeCleanup.utf8)),
        ]
    }

    static let certsYML = #"""
name: OTA certs (certbot)

# Hand-rolled TLS for the on-device OTA server (*.zefv.dev → 127.0.0.1).
#
# Manual DNS-01: certbot hands us two TXT values for _acme-challenge.zefv.dev
# (wildcard + apex). Each is published to challenge.json on the `certs`
# branch (visible in the app's OTA screen and on GitHub); the auth hook then
# polls DNS-over-HTTPS and only returns once the record is live, so Let's
# Encrypt is never asked to validate early. Result → server.crt / server.pem /
# pack.json on `certs`; Build.yml bakes them into every IPA.
#
# CA: Let's Encrypt (default) or ZeroSSL — both ACME, same DNS-01 flow.
# For ZeroSSL set var CA=zerossl and add secrets ZEROSSL_EAB_KID + ZEROSSL_EAB_HMAC
# (ZeroSSL dashboard → Developer → EAB credentials). The app can also pass ca /
# eab_kid / eab_hmac as dispatch inputs.
#
# No secrets required for Let's Encrypt: the app passes `email` as a dispatch input.
# For the weekly cron set var LE_EMAIL (or secret LE_EMAIL). Optional vars: CERT_DOMAIN (zefv.dev), RENEW_DAYS (30),
# WAIT_MINUTES (45), POLL_SECONDS (20).
# Automated alternative: set var DNS_MODE=cloudflare + secret CF_API_TOKEN.

on:
  schedule:
    - cron: "17 4 * * 1"
  workflow_dispatch:
    inputs:
      domain:
        description: "Domain to issue for (wildcard + apex). Blank = vars.CERT_DOMAIN / zefv.dev"
        type: string
        default: ""
      email:
        description: "ACME account email (blank = vars.LE_EMAIL / secrets.LE_EMAIL)"
        type: string
        default: ""
      ca:
        description: "Certificate authority"
        type: choice
        options: [letsencrypt, zerossl]
        default: letsencrypt
      eab_kid:
        description: "ZeroSSL EAB KID (blank = secrets.ZEROSSL_EAB_KID)"
        type: string
        default: ""
      eab_hmac:
        description: "ZeroSSL EAB HMAC (blank = secrets.ZEROSSL_EAB_HMAC)"
        type: string
        default: ""
      force:
        description: "Renew even if the current cert is not near expiry"
        type: boolean
        default: false

permissions:
  contents: write

concurrency:
  group: ota-certs
  cancel-in-progress: false

jobs:
  renew:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    env:
      CERT_DOMAIN:  ${{ inputs.domain || vars.CERT_DOMAIN || 'zefv.dev' }}
      RENEW_DAYS:   ${{ vars.RENEW_DAYS  || '30' }}
      DNS_MODE:     ${{ vars.DNS_MODE    || 'manual' }}
      WAIT_MINUTES: ${{ vars.WAIT_MINUTES || '45' }}
      POLL_SECONDS: ${{ vars.POLL_SECONDS || '20' }}
      CERTS_BRANCH: certs
      CERTS_WT: ${{ github.workspace }}/certs-wt
      LE_EMAIL: ${{ inputs.email || vars.LE_EMAIL || secrets.LE_EMAIL }}
      CA: ${{ inputs.ca || vars.CA || 'letsencrypt' }}
      ZEROSSL_EAB_KID:  ${{ inputs.eab_kid  || secrets.ZEROSSL_EAB_KID }}
      ZEROSSL_EAB_HMAC: ${{ inputs.eab_hmac || secrets.ZEROSSL_EAB_HMAC }}
    steps:
      - name: Checkout main (scripts)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Worktree for certs branch (create if missing)
        run: |
          set -euo pipefail
          git config --global user.name  "ota-certs[bot]"
          git config --global user.email "ota-certs@users.noreply.github.com"
          if git ls-remote --exit-code --heads origin "$CERTS_BRANCH" >/dev/null 2>&1; then
            git fetch origin "$CERTS_BRANCH:$CERTS_BRANCH"
            git worktree add "$CERTS_WT" "$CERTS_BRANCH"
          else
            git worktree add --detach "$CERTS_WT"
            ( cd "$CERTS_WT" && git checkout --orphan "$CERTS_BRANCH" && git rm -rfq . \
              && echo "# OTA certs" > README.md && git add README.md && git commit -qm "init certs branch" \
              && git push -q origin "$CERTS_BRANCH" )
          fi
          ( cd "$CERTS_WT" && git branch --set-upstream-to="origin/$CERTS_BRANCH" "$CERTS_BRANCH" 2>/dev/null || true )
          ls -la "$CERTS_WT"

      - name: Sanity — wildcard should point at loopback
        run: |
          set -euo pipefail
          A=$(curl -sS -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=ota-probe.${CERT_DOMAIN}&type=A" \
              | python3 -c 'import json,sys; print(" ".join(a.get("data","") for a in json.load(sys.stdin).get("Answer",[])))' || true)
          echo "*.${CERT_DOMAIN} → ${A:-<no A record>}"
          case "$A" in *127.*) echo "OK: resolves to loopback";;
            *) echo "::warning title=DNS::*.${CERT_DOMAIN} does not resolve to 127.0.0.1 — the cert will issue, but OTA installs won't work until the wildcard A record points at loopback.";; esac

      - name: Decide whether to renew
        id: decide
        env:
          FORCE: ${{ inputs.force }}
        run: |
          set -euo pipefail
          NEED=yes
          if [ -f "$CERTS_WT/server.crt" ] && [ "${FORCE}" != "true" ]; then
            END=$(openssl x509 -in "$CERTS_WT/server.crt" -noout -enddate | cut -d= -f2)
            DAYS=$(( ($(date -d "$END" +%s) - $(date +%s)) / 86400 ))
            SANS=$(openssl x509 -in "$CERTS_WT/server.crt" -noout -ext subjectAltName | tail -n1)
            echo "Current cert: $SANS — expires in ${DAYS} days ($END)"
            if [ "$DAYS" -gt "$RENEW_DAYS" ] && grep -q "DNS:\*\.${CERT_DOMAIN}" <<<"$SANS"; then NEED=no; fi
          fi
          echo "need=$NEED" >> "$GITHUB_OUTPUT"
          echo "Renew: $NEED"

      - name: Install certbot
        if: steps.decide.outputs.need == 'yes'
        run: |
          set -euo pipefail
          python3 -m pip install --quiet --upgrade pip
          if [ "$DNS_MODE" = "cloudflare" ]; then python3 -m pip install --quiet certbot certbot-dns-cloudflare
          else python3 -m pip install --quiet certbot; fi
          certbot --version

      - name: Reset challenge board
        if: steps.decide.outputs.need == 'yes'
        run: |
          set -euo pipefail
          cd "$CERTS_WT"
          printf '{"records":[],"updatedAt":"%s","instructions":"Waiting for certbot to hand out the TXT values…"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > challenge.json
          git add challenge.json && git commit -qm "acme: start" && git push -q origin "$CERTS_BRANCH"

      - name: Issue certificate — manual DNS-01 (hook waits for your TXT records)
        if: steps.decide.outputs.need == 'yes' && env.DNS_MODE == 'manual'
        run: |
          set -euo pipefail
          [ -n "${LE_EMAIL:-}" ] || { echo "::error::No email — pass it from the app (Renew now) or set repo var LE_EMAIL"; exit 1; }
          chmod +x .github/scripts/acme-*.sh
          # CA selection: Let's Encrypt (default) or ZeroSSL. Both are ACME.
          EAB=()
          if [ "$CA" = "zerossl" ]; then
            SERVER="https://acme.zerossl.com/v2/DV90"
            if [ -n "${ZEROSSL_EAB_KID:-}" ] && [ -n "${ZEROSSL_EAB_HMAC:-}" ]; then
              EAB=(--eab-kid "$ZEROSSL_EAB_KID" --eab-hmac-key "$ZEROSSL_EAB_HMAC")
            else
              # No EAB provided — derive one from the email via ZeroSSL's API.
              echo "no EAB creds — requesting from ZeroSSL API for $LE_EMAIL"
              RESP=$(curl -sS -X POST "https://api.zerossl.com/acme/eab-credentials-email" --data "email=$LE_EMAIL")
              KID=$(echo "$RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("eab_kid",""))')
              HMAC=$(echo "$RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("eab_hmac_key",""))')
              [ -n "$KID" ] && [ -n "$HMAC" ] || { echo "::error::ZeroSSL EAB request failed: $RESP"; exit 1; }
              EAB=(--eab-kid "$KID" --eab-hmac-key "$HMAC")
            fi
          else
            SERVER="https://acme-v02.api.letsencrypt.org/directory"
          fi
          echo "CA: $CA  server: $SERVER"
          mkdir -p le
          certbot certonly \
            --non-interactive --agree-tos --email "$LE_EMAIL" \
            --server "$SERVER" "${EAB[@]}" \
            --config-dir ./le --work-dir ./le/work --logs-dir ./le/logs \
            --manual --preferred-challenges dns \
            --manual-auth-hook    "$PWD/.github/scripts/acme-auth.sh" \
            --manual-cleanup-hook "$PWD/.github/scripts/acme-cleanup.sh" \
            --key-type ecdsa --elliptic-curve secp256r1 \
            --cert-name "$CERT_DOMAIN" \
            -d "*.${CERT_DOMAIN}" -d "${CERT_DOMAIN}"
          LIVE=$(ls -d le/live/*/ 2>/dev/null | grep -vi README | head -1)
          [ -n "$LIVE" ] || { echo "::error::certbot produced no le/live/* directory"; exit 1; }
          echo "cert dir: $LIVE"
          cp "${LIVE}fullchain.pem" "$CERTS_WT/server.crt"
          cp "${LIVE}privkey.pem"   "$CERTS_WT/server.pem"
          openssl x509 -in "$CERTS_WT/server.crt" -noout -subject -enddate
          rm -rf le

      - name: Issue certificate — Cloudflare DNS-01 (automated)
        if: steps.decide.outputs.need == 'yes' && env.DNS_MODE == 'cloudflare'
        env:
          CF_API_TOKEN: ${{ secrets.CF_API_TOKEN }}
        run: |
          set -euo pipefail
          [ -n "${LE_EMAIL:-}" ] && [ -n "${CF_API_TOKEN:-}" ] || { echo "::error::Set LE_EMAIL and CF_API_TOKEN"; exit 1; }
          umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > dns.ini
          mkdir -p le
          certbot certonly --non-interactive --agree-tos --email "$LE_EMAIL" \
            --config-dir ./le --work-dir ./le/work --logs-dir ./le/logs \
            --dns-cloudflare --dns-cloudflare-credentials ./dns.ini --dns-cloudflare-propagation-seconds 60 \
            --key-type ecdsa --elliptic-curve secp256r1 --cert-name "$CERT_DOMAIN" \
            -d "*.${CERT_DOMAIN}" -d "${CERT_DOMAIN}"
          LIVE=$(ls -d le/live/*/ 2>/dev/null | grep -vi README | head -1)
          [ -n "$LIVE" ] || { echo "::error::certbot produced no le/live/* directory"; exit 1; }
          cp "${LIVE}fullchain.pem" "$CERTS_WT/server.crt"
          cp "${LIVE}privkey.pem"   "$CERTS_WT/server.pem"
          rm -f dns.ini; rm -rf le

      - name: Write pack.json & publish
        if: steps.decide.outputs.need == 'yes'
        run: |
          set -euo pipefail
          cd "$CERTS_WT"
          [ -s server.crt ] && [ -s server.pem ] || { echo "::error::server.crt/server.pem missing — issuance failed before publish"; exit 1; }
          openssl x509 -in server.crt -noout >/dev/null || { echo "::error::server.crt is not a valid certificate"; exit 1; }
          END=$(openssl x509 -in server.crt -noout -enddate | cut -d= -f2)
          START=$(openssl x509 -in server.crt -noout -startdate | cut -d= -f2)
          EXP_ISO=$(date -u -d "$END"   +%Y-%m-%dT%H:%M:%SZ)
          ISS_ISO=$(date -u -d "$START" +%Y-%m-%dT%H:%M:%SZ)
          SANS=$(openssl x509 -in server.crt -noout -ext subjectAltName | tail -n1 | sed 's/^ *//')
          cat > pack.json <<JSON
          {
            "bundle": "server.crt",
            "key": "server.pem",
            "expires": "$EXP_ISO",
            "issued": "$ISS_ISO",
            "commonName": "*.${CERT_DOMAIN}",
            "sans": "$SANS",
            "sha256": { "bundle": "$(sha256sum server.crt | cut -d' ' -f1)", "key": "$(sha256sum server.pem | cut -d' ' -f1)" },
            "issuer": "$CA",
            "mode": "$DNS_MODE",
            "generatedBy": "certs.yml @ ${GITHUB_SHA}"
          }
          JSON
          printf '{"records":[],"updatedAt":"%s","instructions":"Done — cert issued. You can delete the _acme-challenge TXT records."}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > challenge.json
          git add server.crt server.pem pack.json challenge.json
          git commit -qm "renew *.${CERT_DOMAIN} — expires $EXP_ISO"
          # The auth hook pushed challenge.json commits during the run, so our
          # local branch is behind origin. Rebase and retry so the push lands.
          for attempt in 1 2 3; do
            if git push origin "$CERTS_BRANCH"; then echo "pushed (attempt $attempt)"; break; fi
            echo "push rejected — rebasing onto origin/$CERTS_BRANCH (attempt $attempt)"
            git fetch -q origin "$CERTS_BRANCH"
            git rebase -X ours "origin/$CERTS_BRANCH" || git rebase --abort
            [ "$attempt" = 3 ] && { echo "::error::could not push cert to $CERTS_BRANCH after 3 tries"; exit 1; }
          done
          echo "verify on origin:"
          git ls-tree --name-only "origin/$CERTS_BRANCH" | grep -E "server.crt|server.pem|pack.json" || echo "::warning::files not visible on origin listing yet"
          openssl x509 -in server.crt -noout -subject -issuer -enddate

      - name: Summary
        if: always()
        run: |
          {
            echo "## OTA cert"
            if [ -f "$CERTS_WT/server.crt" ]; then echo '```'; openssl x509 -in "$CERTS_WT/server.crt" -noout -subject -enddate; echo '```'; else echo "no cert on branch yet"; fi
            echo "renewed this run: **${{ steps.decide.outputs.need }}** (mode: $DNS_MODE)"
            if [ -f "$CERTS_WT/challenge.json" ]; then echo '```json'; cat "$CERTS_WT/challenge.json"; echo '```'; fi
          } >> "$GITHUB_STEP_SUMMARY"

"""#

    static let acmeAuth = #"""
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

"""#

    static let acmeCleanup = #"""
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

"""#
}
