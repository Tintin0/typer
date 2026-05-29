#!/usr/bin/env bash
# Create a STABLE self-signed code-signing certificate for Typer.
#
# Why: Typer is rebuilt constantly. Ad-hoc signing (`codesign --sign -`) gives the
# app a designated requirement based on its cdhash, which changes on every build.
# macOS TCC keys the Accessibility / Input Monitoring grant to that requirement, so
# every rebuild silently revokes trust and the event tap dies ("AX trusted=false").
#
# Signing with a persistent self-signed certificate instead anchors the designated
# requirement to the certificate identity:
#     identifier "local.typer.menubar" and certificate leaf = H"<stable hash>"
# That hash is constant across rebuilds, so the TCC grant survives. No Apple
# Developer Program membership is required for a self-signed certificate.
#
# Run this ONCE. After granting Accessibility to the freshly signed app a single
# time, future `build.sh` runs keep the grant.
set -euo pipefail

CERT_CN="${TYPER_SIGN_CN:-Typer Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
[ -f "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
  echo "Signing identity '$CERT_CN' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# If a cert with this name already exists (e.g. from a previous run that created
# it but trust wasn't applied), reuse it instead of generating a duplicate.
if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Certificate '$CERT_CN' already in keychain (untrusted) — re-applying trust."
  security find-certificate -c "$CERT_CN" -p "$KEYCHAIN" > "$TMP/cert.pem"
else
  cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CERT_CN
[ v3 ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

  echo "Generating self-signed code-signing certificate '$CERT_CN'..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

  # Import the key and certificate as separate PEM files. We deliberately avoid
  # `openssl pkcs12 -export` because OpenSSL 3 writes a SHA-256 PKCS#12 MAC that
  # Apple's `security import` cannot verify ("MAC verification failed"). Importing
  # the PEMs separately sidesteps that entirely. -T lets codesign use the key.
  security import "$TMP/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
fi

# Trust the self-signed root for the Code Signing policy. This is REQUIRED — an
# untrusted self-signed identity reports CSSMERR_TP_NOT_TRUSTED and codesign will
# refuse to use it. Adding trust in the user domain raises one standard macOS
# authorization dialog (enter your login password). This is a one-time step.
echo "Granting code-signing trust to the certificate (approve the macOS dialog)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

# Avoid the "codesign wants to use a key" prompt on every build by adding codesign
# to the key's partition list. This needs the login keychain password.
echo
echo "To let codesign use the new key WITHOUT prompting on every build, enter your"
echo "macOS login password. (Press Enter to skip — you'll click 'Always Allow' once.)"
read -r -s -p "Login password: " PW; echo
if [ -n "$PW" ]; then
  if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Key partition list updated — signing will be non-interactive."
  else
    echo "Could not update partition list; click 'Always Allow' once on first build."
  fi
fi

echo
echo "Done. Identity created:"
security find-identity -v -p codesigning | grep -F "$CERT_CN" || true
echo
echo "Next: run scripts/build.sh, then grant Accessibility to Typer.app once."
