//
//  CertPipeline.swift
//  The certbot pipeline files, embedded so the app can install them into any
//  repo with one tap (Settings › OTA Domain › Link repo). Keep in sync with
//  the copies under .github/ — these are byte-for-byte the same.
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
# No secrets required: the app passes `email` as a dispatch input. For the
# weekly cron set var LE_EMAIL (or secret LE_EMAIL). Optional vars: CERT_DOMAIN (zefv.dev), RENEW_DAYS (30),
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
        description: "Let's Encrypt account email (blank = vars.LE_EMAIL / secrets.LE_EMAIL)"
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
          mkdir -p le
          certbot certonly \
            --non-interactive --agree-tos --email "$LE_EMAIL" \
            --config-dir ./le --work-dir ./le/work --logs-dir ./le/logs \
            --manual --preferred-challenges dns \
            --manual-auth-hook    "$PWD/.github/scripts/acme-auth.sh" \
            --manual-cleanup-hook "$PWD/.github/scripts/acme-cleanup.sh" \
            --key-type ecdsa --elliptic-curve secp256r1 \
            --cert-name "$CERT_DOMAIN" \
            -d "*.${CERT_DOMAIN}" -d "${CERT_DOMAIN}"
          cp "le/live/${CERT_DOMAIN}/fullchain.pem" "$CERTS_WT/server.crt"
          cp "le/live/${CERT_DOMAIN}/privkey.pem"   "$CERTS_WT/server.pem"
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
          cp "le/live/${CERT_DOMAIN}/fullchain.pem" "$CERTS_WT/server.crt"
          cp "le/live/${CERT_DOMAIN}/privkey.pem"   "$CERTS_WT/server.pem"
          rm -f dns.ini; rm -rf le

      - name: Write pack.json & publish
        if: steps.decide.outputs.need == 'yes'
        run: |
          set -euo pipefail
          cd "$CERTS_WT"
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
            "issuer": "letsencrypt",
            "mode": "$DNS_MODE",
            "generatedBy": "certs.yml @ ${GITHUB_SHA}"
          }
          JSON
          printf '{"records":[],"updatedAt":"%s","instructions":"Done — cert issued. You can delete the _acme-challenge TXT records."}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > challenge.json
          git add server.crt server.pem pack.json challenge.json
          git commit -qm "renew *.${CERT_DOMAIN} — expires $EXP_ISO"
          git push -q origin "$CERTS_BRANCH"
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
