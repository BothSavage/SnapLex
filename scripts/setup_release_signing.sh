#!/usr/bin/env bash
set -euo pipefail

IDENTITY="SnapLex Stable Code Signing"
PASSWORD_SERVICE="io.github.snaplex.release-signing-p12"
SIGNING_KEYCHAIN_PASSWORD_SERVICE="io.github.snaplex.release-signing-keychain"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${SNAPLEX_GITHUB_REPOSITORY:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This setup must run on macOS." >&2
    exit 1
fi
for command_name in gh openssl security; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is missing: $command_name" >&2
        exit 1
    fi
done

if [[ -z "$REPOSITORY" ]]; then
    REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
    REPOSITORY="$(printf '%s' "$REMOTE_URL" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
fi
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Could not determine GitHub owner/repository. Set SNAPLEX_GITHUB_REPOSITORY=owner/repo." >&2
    exit 1
fi
GH_AUTHENTICATED=0
if gh auth status --hostname github.com >/dev/null 2>&1; then
    GH_AUTHENTICATED=1
fi

PERSIST_DIR="${HOME}/Library/Application Support/SnapLex/Signing"
P12_PATH="$PERSIST_DIR/SnapLex-Stable-Code-Signing.p12"
SIGNING_KEYCHAIN_PATH="$PERSIST_DIR/SnapLex-Stable-Signing.keychain-db"
LOGIN_KEYCHAIN="$(security login-keychain | sed -E 's/^[[:space:]]*"//; s/"$//')"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snaplex-signing.XXXXXX")"
TEMP_BASE64_PATH=""
cleanup() {
    rm -rf "$TEMP_DIR"
    if [[ -n "$TEMP_BASE64_PATH" ]]; then rm -f "$TEMP_BASE64_PATH"; fi
}
trap cleanup EXIT

mkdir -p "$PERSIST_DIR"
chmod 700 "$PERSIST_DIR"

if [[ -f "$P12_PATH" ]]; then
    chmod 600 "$P12_PATH"
    P12_PASSWORD="$(security find-generic-password -a "$(id -un)" -s "$PASSWORD_SERVICE" -w "$LOGIN_KEYCHAIN" 2>/dev/null || true)"
    if [[ -z "$P12_PASSWORD" ]]; then
        read -r -s -p "Enter the existing P12 password for $IDENTITY: " P12_PASSWORD
        printf '\n'
    fi
    openssl pkcs12 -in "$P12_PATH" -clcerts -nokeys -passin "pass:$P12_PASSWORD" \
        -out "$TEMP_DIR/signing-certificate.pem"
else
    if [[ -f "$SIGNING_KEYCHAIN_PATH" ]]; then
        echo "The SnapLex signing keychain exists, but its P12 backup is missing." >&2
        echo "Refusing to create a replacement because changing the certificate changes SnapLex's macOS permission identity." >&2
        exit 1
    fi

    PRIVATE_KEY_PATH="$TEMP_DIR/signing-key.pem"
    CERTIFICATE_PEM_PATH="$TEMP_DIR/signing-certificate.pem"
    OPENSSL_CONFIG="$TEMP_DIR/openssl.cnf"
    cat > "$OPENSSL_CONFIG" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no

[subject]
CN = SnapLex Stable Code Signing

[code_signing]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
    openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
        -config "$OPENSSL_CONFIG" -keyout "$PRIVATE_KEY_PATH" -out "$CERTIFICATE_PEM_PATH"
    P12_PASSWORD="$(openssl rand -hex 32)"
    openssl pkcs12 -export -inkey "$PRIVATE_KEY_PATH" -in "$CERTIFICATE_PEM_PATH" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -name "$IDENTITY" -passout "pass:$P12_PASSWORD" -out "$P12_PATH"
    chmod 600 "$P12_PATH"
fi

CERTIFICATE_PEM_PATH="$TEMP_DIR/signing-certificate.pem"
CERTIFICATE_DER_PATH="$TEMP_DIR/signing-certificate.cer"
openssl x509 -in "$CERTIFICATE_PEM_PATH" -outform DER -out "$CERTIFICATE_DER_PATH"
security add-generic-password -U -a "$(id -un)" -s "$PASSWORD_SERVICE" \
    -w "$P12_PASSWORD" "$LOGIN_KEYCHAIN" >/dev/null
SIGNING_KEYCHAIN_PASSWORD="$(security find-generic-password -a "$(id -un)" -s "$SIGNING_KEYCHAIN_PASSWORD_SERVICE" -w "$LOGIN_KEYCHAIN" 2>/dev/null || true)"
if [[ -f "$SIGNING_KEYCHAIN_PATH" ]]; then
    if [[ -z "$SIGNING_KEYCHAIN_PASSWORD" ]]; then
        echo "The SnapLex signing keychain exists, but its unlock password is missing from the login keychain." >&2
        exit 1
    fi
    security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN_PATH"
else
    SIGNING_KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
    security create-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN_PATH"
    security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN_PATH"
    security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN_PATH"
    security add-generic-password -U -a "$(id -un)" -s "$SIGNING_KEYCHAIN_PASSWORD_SERVICE" \
        -w "$SIGNING_KEYCHAIN_PASSWORD" "$LOGIN_KEYCHAIN" >/dev/null
fi

SIGNING_KEYCHAIN_IDENTITY="$(security find-identity -p codesigning "$SIGNING_KEYCHAIN_PATH" | grep -F "\"$IDENTITY\"" || true)"
if [[ -z "$SIGNING_KEYCHAIN_IDENTITY" ]]; then
    if ! security import "$P12_PATH" -k "$SIGNING_KEYCHAIN_PATH" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null 2>&1; then
        # OpenSSL 3 defaults to PBES2/AES and SHA-256 MAC, which some macOS
        # Keychain import versions reject as a misleading password failure.
        export P12_PASSWORD
        openssl pkcs12 -in "$P12_PATH" -nocerts -nodes -passin env:P12_PASSWORD \
            -out "$TEMP_DIR/signing-key.pem"
        openssl pkcs12 -in "$P12_PATH" -clcerts -nokeys -passin env:P12_PASSWORD \
            -out "$TEMP_DIR/signing-certificate.pem"
        openssl pkcs12 -export -inkey "$TEMP_DIR/signing-key.pem" \
            -in "$TEMP_DIR/signing-certificate.pem" -keypbe PBE-SHA1-3DES \
            -certpbe PBE-SHA1-3DES -macalg sha1 -name "$IDENTITY" \
            -passout env:P12_PASSWORD -out "$TEMP_DIR/compatible.p12"
        security import "$TEMP_DIR/compatible.p12" -k "$SIGNING_KEYCHAIN_PATH" \
            -P "$P12_PASSWORD" -T /usr/bin/codesign
        mv "$TEMP_DIR/compatible.p12" "$P12_PATH"
    fi
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \
    "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN_PATH" >/dev/null
if ! security verify-cert -c "$CERTIFICATE_DER_PATH" -p codeSign \
    -k "$SIGNING_KEYCHAIN_PATH" -L -l >/dev/null 2>&1; then
    security add-trusted-cert -r trustRoot -p codeSign -k "$SIGNING_KEYCHAIN_PATH" \
        "$CERTIFICATE_DER_PATH" >/dev/null
fi

CERT_SHA1="$(openssl x509 -in "$CERTIFICATE_PEM_PATH" -noout -fingerprint -sha1 | sed -E 's/^[^=]+=//; s/://g' | tr '[:lower:]' '[:upper:]')"

IDENTITY_LINE="$(security find-identity -p codesigning "$SIGNING_KEYCHAIN_PATH" | grep -F "\"$IDENTITY\"" | head -n 1 || true)"
LOCAL_CERT_SHA1="$(printf '%s' "$IDENTITY_LINE" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')"
if [[ "$LOCAL_CERT_SHA1" != "$CERT_SHA1" ]]; then
    echo "The stable signing certificate does not match the identity in the dedicated SnapLex signing keychain." >&2
    exit 1
fi
chmod 600 "$SIGNING_KEYCHAIN_PATH"

TEMP_BASE64_PATH="$TEMP_DIR/signing-p12.base64"
base64 < "$P12_PATH" | tr -d '\n' > "$TEMP_BASE64_PATH"
if [[ "$GH_AUTHENTICATED" != 1 ]]; then
    echo "Installed the fixed signing identity in the dedicated local SnapLex signing keychain."
    echo "GitHub CLI is not authenticated, so Actions secrets were not changed. Run 'gh auth login', then rerun this script to sync the existing certificate."
    echo "Certificate SHA-1: $CERT_SHA1"
    echo "Private P12 backup: $P12_PATH"
    echo "Signing keychain: $SIGNING_KEYCHAIN_PATH"
    exit 0
fi

gh secret set SNAPLEX_SIGNING_CERTIFICATE_P12_BASE64 --repo "$REPOSITORY" < "$TEMP_BASE64_PATH"
printf '%s' "$P12_PASSWORD" | gh secret set SNAPLEX_SIGNING_CERTIFICATE_PASSWORD --repo "$REPOSITORY"
gh variable set SNAPLEX_SIGNING_CERT_SHA1 --repo "$REPOSITORY" --body "$CERT_SHA1"

echo "Configured the fixed SnapLex signing identity for $REPOSITORY."
echo "Certificate SHA-1: $CERT_SHA1"
echo "The private P12 is stored in the user-only directory: $P12_PATH"
echo "The local signing keychain is: $SIGNING_KEYCHAIN_PATH"
if ! gh secret list --repo "$REPOSITORY" | awk '$1 == "SPARKLE_EDDSA_PRIVATE_KEY" { found = 1 } END { exit !found }'; then
    echo "Add the required SPARKLE_EDDSA_PRIVATE_KEY repository secret before publishing a release." >&2
fi
