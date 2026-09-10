<?php
// api.zefv.dev/ota/cert.php — serves the live *.zefv.dev wildcard pair to the
// signer app. certbot (dns-cloudflare) renews it; the deploy hook already
// mirrors the files to /var/certs/, so this is always the current cert.
//
// Install:  sudo mkdir -p /var/www/api/ota && sudo cp cert.php /var/www/api/ota/
//           (adjust to wherever api.zefv.dev's docroot is)
// The app sends the token in X-OTA-Token (default zefv-ota-2026; change both
// here and in the app's "Cert source" card if you rotate it).

$TOKEN     = getenv('OTA_CERT_TOKEN') ?: 'zefv-ota-2026';
$FULLCHAIN = '/var/certs/fullchain.pem';
$PRIVKEY   = '/var/certs/privkey.pem';

header('Content-Type: application/json');
header('Cache-Control: no-store');

$hdr = $_SERVER['HTTP_X_OTA_TOKEN'] ?? ($_GET['token'] ?? '');
if (!hash_equals($TOKEN, $hdr)) { http_response_code(401); echo json_encode(['error' => 'bad token']); exit; }

$cert = @file_get_contents($FULLCHAIN);
$key  = @file_get_contents($PRIVKEY);
if ($cert === false || $key === false) { http_response_code(500); echo json_encode(['error' => 'cert files unreadable — check /var/certs perms (www-data needs read)']); exit; }

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

echo json_encode(['cert' => $cert, 'key' => $key, 'not_after' => $notAfter, 'sans' => $sans, 'domain' => 'zefv.dev']);
