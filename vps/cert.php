<?php
// api.zefv.dev/ota/cert.php — serves the live *.zefv.dev wildcard pair to the
// signer app. certbot (dns-cloudflare) renews it on this VPS and the deploy
// hook mirrors it to /var/certs/, so this is always the current cert.
//
// Files in /var/certs (as deployed):  zefv.dev.crt  zefv.dev.key  zefv.dev.chain  zefv.dev.leaf
// The app needs the FULL chain (leaf + intermediates) — built below if .crt is leaf-only.
//
// Install: copy to <api.zefv.dev docroot>/ota/cert.php and make sure www-data
// can read /var/certs/zefv.dev.key (e.g. chgrp www-data + chmod 640).
// Token: header X-OTA-Token (default zefv-ota-2026 — same default in the app's
// "Cert source" card; set OTA_CERT_TOKEN in the Apache vhost to rotate).

$TOKEN = getenv('OTA_CERT_TOKEN') ?: 'zefv-ota-2026';
$DIR   = '/var/certs';
$NAME  = 'zefv.dev';

header('Content-Type: application/json');
header('Cache-Control: no-store');

$hdr = $_SERVER['HTTP_X_OTA_TOKEN'] ?? ($_GET['token'] ?? '');
if (!hash_equals($TOKEN, $hdr)) { http_response_code(401); echo json_encode(['error' => 'bad token']); exit; }

function first_readable(array $paths) { foreach ($paths as $p) { if (is_readable($p)) return $p; } return null; }

$certFile  = first_readable(["$DIR/$NAME.fullchain", "$DIR/$NAME.crt", "$DIR/$NAME.leaf", "$DIR/fullchain.pem", "$DIR/cert.pem"]);
$chainFile = first_readable(["$DIR/$NAME.chain", "$DIR/chain.pem"]);
$keyFile   = first_readable(["$DIR/$NAME.key", "$DIR/privkey.pem"]);

if (!$certFile || !$keyFile) {
    http_response_code(500);
    echo json_encode(['error' => "cert/key unreadable in $DIR — www-data needs read on $NAME.crt and $NAME.key"]);
    exit;
}

$cert = file_get_contents($certFile);
$key  = file_get_contents($keyFile);

// Leaf-only .crt? Append the intermediate chain so iOS/Vapor get a full chain.
if (substr_count($cert, 'BEGIN CERTIFICATE') < 2 && $chainFile) {
    $cert = rtrim($cert) . "\n" . file_get_contents($chainFile);
}

$sans = []; $notAfter = null;
if (($x = @openssl_x509_parse($cert)) !== false) {
    $notAfter = gmdate('Y-m-d\TH:i:s\Z', $x['validTo_time_t']);
    if (!empty($x['extensions']['subjectAltName'])) {
        foreach (explode(',', $x['extensions']['subjectAltName']) as $e) {
            $e = trim($e);
            if (stripos($e, 'DNS:') === 0) $sans[] = substr($e, 4);
        }
    }
}

echo json_encode(['cert' => $cert, 'key' => $key, 'not_after' => $notAfter, 'sans' => $sans, 'domain' => $NAME]);
