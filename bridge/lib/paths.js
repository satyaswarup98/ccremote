import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const HOME = os.homedir();
export const STATE_DIR = path.join(HOME, '.ccremote');
export const TLS_DIR = path.join(STATE_DIR, 'tls');
export const CONFIG_FILE = path.join(STATE_DIR, 'config.json');
export const DEVICES_FILE = path.join(STATE_DIR, 'devices.json');
export const SECRET_FILE = path.join(STATE_DIR, 'hook.secret');
export const LOG_FILE = path.join(STATE_DIR, 'bridge.log');
export const LOCAL_PORT = 8788;   // hooks + CLI, loopback only
export const PUBLIC_PORT = 8787;  // phone, TLS

const DEFAULT_CONFIG = {
  port: PUBLIC_PORT,
  // 'auto' = away when the Mac has had no keyboard/mouse input for idleThresholdSec
  awayMode: 'auto',
  idleThresholdSec: 120,
  // how long a finished turn waits for a message from the phone while away
  // While away, a finished turn waits this long for a reply from the phone (works with the screen locked).
  stopHoldSec: 3540,
  // While the Mac is locked, a finished turn waits up to 12 hours for a reply (released when you unlock).
  lockedHoldSec: 43140,
  // Keep the Mac from sleeping while it's on power, so the phone can reach it (caffeinate -s).
  keepAwakeOnPower: true,
  // Send to VS Code waits for a pause this long in keyboard/mouse input (so it doesn't mix with your
  // typing), for up to vscodeWaitSec, then types quickly and returns you to the app you were in.
  vscodeQuietSec: 1.5,
  vscodeWaitSec: 20,
  ntfyServer: 'https://ntfy.sh',
  ntfyTopic: null,
  ntfyDetail: true,
};

export function ensureStateDir() {
  fs.mkdirSync(TLS_DIR, { recursive: true, mode: 0o700 });
  if (!fs.existsSync(SECRET_FILE)) {
    fs.writeFileSync(SECRET_FILE, crypto.randomBytes(24).toString('hex'), { mode: 0o600 });
  }
  if (!fs.existsSync(path.join(TLS_DIR, 'cert.pem'))) {
    // Works with macOS's built-in LibreSSL as well as OpenSSL 3. Must be an X.509 v3 cert with a
    // *named* P-256 curve: iOS rejects certs that spell out the curve parameters.
    const openssl = ['/usr/bin/openssl', '/opt/homebrew/opt/openssl@3/bin/openssl', '/usr/local/opt/openssl@3/bin/openssl'].find(p => fs.existsSync(p));
    if (!openssl) throw new Error('openssl not found');
    const cnf = path.join(TLS_DIR, 'cert.cnf');
    fs.writeFileSync(cnf, [
      '[req]', 'distinguished_name = dn', 'x509_extensions = v3', 'prompt = no',
      '[dn]', 'CN = ccremote-bridge',
      '[v3]', 'subjectAltName = DNS:ccremote-bridge', 'extendedKeyUsage = serverAuth', 'basicConstraints = critical,CA:FALSE', '',
    ].join('\n'));
    execFileSync(openssl, ['ecparam', '-name', 'prime256v1', '-param_enc', 'named_curve', '-genkey', '-noout', '-out', path.join(TLS_DIR, 'key.pem')], { stdio: 'ignore' });
    execFileSync(openssl, ['req', '-new', '-x509', '-key', path.join(TLS_DIR, 'key.pem'), '-out', path.join(TLS_DIR, 'cert.pem'),
      '-days', '825', '-sha256', '-config', cnf], { stdio: 'ignore' });
    fs.unlinkSync(cnf);
    fs.chmodSync(path.join(TLS_DIR, 'key.pem'), 0o600);
  }
  const cfg = loadConfig();
  // Older installs saved the previous 14-minute default; move them to the new one (custom values stay).
  if (cfg.stopHoldSec === 840) { cfg.stopHoldSec = DEFAULT_CONFIG.stopHoldSec; saveConfig(cfg); }
  if (!cfg.ntfyTopic) {
    cfg.ntfyTopic = 'ccr-' + crypto.randomBytes(12).toString('hex');
    saveConfig(cfg);
  }
}

export function loadConfig() {
  try {
    return { ...DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')) };
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

export function saveConfig(cfg) {
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2), { mode: 0o600 });
}

export function readSecret() {
  return fs.readFileSync(SECRET_FILE, 'utf8').trim();
}

// SHA-256 of the certificate's DER bytes, the same value iOS computes from SecCertificateCopyData.
export function certFingerprint() {
  const pem = fs.readFileSync(path.join(TLS_DIR, 'cert.pem'), 'utf8');
  return new crypto.X509Certificate(pem).fingerprint256.replace(/:/g, '').toLowerCase();
}
