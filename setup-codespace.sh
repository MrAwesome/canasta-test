#!/usr/bin/env bash
#
# Reproducible Canasta + Semantic MediaWiki setup on a GitHub Codespace.
#
# Based on SETUP.md, with fixes for behavior observed with Canasta CLI
# 4.33.0 and GitHub Codespaces in November 2026:
#
#   * Wiki ID "wiki" is reserved by the current CLI; this uses "main".
#   * get.canasta.wiki is not reachable from every Codespace, so the
#     installer is fetched locally and copied over SSH instead.
#   * Codespaces' public port proxy sends "Host: localhost:8080" to the
#     backend, not the "-8080.app.github.dev" host. Canasta's edge maps
#     on the Host header, so the wiki URL is kept as localhost:8080 and
#     MediaWiki canonical URLs are forced to the public HTTPS origin.
#   * Current Canasta creates a private wiki by default. The test wiki
#     is made publicly readable, with anonymous editing disabled.
#
# Instance settings and credentials are read from .env next to this script:
#   CODESPACE_NAME=...
#   CANASTA_USER=...
#   CANASTA_PASS=...
#   BOT_USER=...
#   BOT_PASS=...
#
# Usage:
#   ./setup-codespace.sh
#   CODESPACE_NAME=my-codespace ./setup-codespace.sh
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

ENV_FILE=${ENV_FILE:-$SCRIPT_DIR/.env}
INSTANCE_ID=${INSTANCE_ID:-smwtest}
WIKI_ID=${WIKI_ID:-main}
HTTP_PORT=${HTTP_PORT:-8080}
LOCAL_FORWARD_PORT=${LOCAL_FORWARD_PORT:-18080}

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing $ENV_FILE with CODESPACE_NAME, CANASTA_USER, CANASTA_PASS, BOT_USER and BOT_PASS" >&2
    exit 1
fi

# Keep an explicitly exported CODESPACE_NAME working even when .env sets one.
CODESPACE_NAME_OVERRIDE=${CODESPACE_NAME:-}
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
CODESPACE_NAME=${CODESPACE_NAME_OVERRIDE:-${CODESPACE_NAME:-}}
: "${CODESPACE_NAME:?CODESPACE_NAME is not set (add it to $ENV_FILE)}"
: "${CANASTA_USER:?CANASTA_USER is not set}"
: "${CANASTA_PASS:?CANASTA_PASS is not set}"
: "${BOT_USER:?BOT_USER is not set}"
: "${BOT_PASS:?BOT_PASS is not set}"

say() {
    printf '\n==> %s\n' "$*"
}

# Run a bash script inside the Codespace. The script is base64 encoded so
# quoting and nesting do not depend on the local shell.
remote() {
    local b64
    b64=$(base64 -w0)
    gh codespace ssh -c "$CODESPACE_NAME" -- \
        "printf %s '$b64' | base64 -d | bash"
}

say "Checking codespace and Docker"
remote <<'EOF'
set -euo pipefail
docker --version
docker compose version
id -nG
EOF

say "Installing the Canasta CLI if needed"
if ! remote <<'EOF'
command -v canasta >/dev/null 2>&1
EOF
then
    INSTALLER=$(mktemp)
    curl -fsSL https://get.canasta.wiki -o "$INSTALLER"
    INSTALLER_B64=$(base64 -w0 "$INSTALLER")
    remote <<EOF
set -euo pipefail
printf %s '$INSTALLER_B64' | base64 -d > /tmp/canasta-install.sh
sudo bash /tmp/canasta-install.sh
EOF
    rm -f "$INSTALLER"
fi
remote <<'EOF'
set -euo pipefail
canasta version
canasta doctor || true
EOF

say "Building the public hostname and custom.env"
remote <<'EOF'
set -euo pipefail
CODESPACE_NAME=$(grep -m1 '^CODESPACE_NAME=' /workspaces/.codespaces/shared/.env | cut -d= -f2)
DOMAIN=$(grep -m1 '^GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN=' /workspaces/.codespaces/shared/.env | cut -d= -f2)
WIKI_HOST="$CODESPACE_NAME-8080.${DOMAIN:-app.github.dev}"
printf 'CODESPACE_NAME=%s\nWIKI_HOST=%s\n' "$CODESPACE_NAME" "$WIKI_HOST" > "$HOME/canasta-setup.env"
printf 'TLS_MODE=off\nHTTP_PORT=8080\n' > "$HOME/custom.env"
cat "$HOME/canasta-setup.env"
EOF

WIKI_HOST=$(remote <<'EOF'
set -euo pipefail
. "$HOME/canasta-setup.env"
printf %s "$WIKI_HOST"
EOF
)

say "Creating the Canasta instance (5-15 minutes on first run)"
if remote <<EOF
set -euo pipefail
test -f "\$HOME/$INSTANCE_ID/docker-compose.yml"
EOF
then
    echo "Instance '$INSTANCE_ID' already exists, skipping create"
else
    remote <<EOF
set -euo pipefail
cd "\$HOME"
. ./canasta-setup.env
canasta create -i '$INSTANCE_ID' -w '$WIKI_ID' -n "\$WIKI_HOST" -e custom.env
EOF
fi

say "Configuring the public URL for the Codespaces proxy"
WIKI_HOST_B64=$(printf '%s' "$WIKI_HOST" | base64 -w0)
remote <<EOF
set -euo pipefail
cd "\$HOME/$INSTANCE_ID"
WIKI_HOST=\$(printf %s '$WIKI_HOST_B64' | base64 -d)

# The proxy in front of the Codespace sends Host: localhost:8080. Point the
# wiki URL at that host so the Canasta edge routes the request, but keep
# MW_SITE_SERVER on the public HTTPS origin. Edit .env and wikis.yaml
# directly: "canasta config set" cascades FQDN and wiki URLs into each other.
sed -i "s|^MW_SITE_SERVER=.*|MW_SITE_SERVER=https://\$WIKI_HOST|" .env
sed -i "s|^MW_SITE_FQDN=.*|MW_SITE_FQDN=localhost|" .env
sed -i "s|^  url: .*|  url: localhost:8080|" config/wikis.yaml

mkdir -p config/settings/wikis/$WIKI_ID config/settings/global
cat > config/settings/wikis/$WIKI_ID/ForceServer.php <<'PHP'
<?php
// Codespaces forwards Host: localhost:8080 to the backend while exposing
// the wiki at a public HTTPS URL. FarmConfigLoader derives \$wgServer from
// the request host, so override it with the public origin here.
\$wgServer = "https://$WIKI_HOST";
\$wgCanonicalServer = \$wgServer;
\$wgInternalServer = \$wgServer;
PHP

cat > config/settings/global/PublicRead.php <<'PHP'
<?php
// Public test wiki: allow anonymous read, block anonymous edit and
// account creation. Canasta's current defaults make the wiki private.
\$wgGroupPermissions['*']['read'] = true;
\$wgGroupPermissions['*']['edit'] = false;
\$wgGroupPermissions['*']['createaccount'] = false;
PHP

cat > config/settings/global/SemanticMediaWiki.php <<'PHP'
<?php
wfLoadExtension( 'SemanticMediaWiki' );
enableSemantics( '$WIKI_HOST' );
PHP

canasta restart --id '$INSTANCE_ID'
EOF

say "Exposing port $HTTP_PORT publicly"
FORWARD_PIDFILE="/tmp/canasta-${CODESPACE_NAME}-${HTTP_PORT}-forward.pid"
FORWARD_LOG="${FORWARD_PIDFILE%.pid}.log"
if [[ -f "$FORWARD_PIDFILE" ]]; then
    OLD_FORWARD_PID=$(cat "$FORWARD_PIDFILE" 2>/dev/null || true)
    if [[ -n "$OLD_FORWARD_PID" ]]; then
        kill "$OLD_FORWARD_PID" 2>/dev/null || true
        pkill -P "$OLD_FORWARD_PID" 2>/dev/null || true
    fi
    rm -f "$FORWARD_PIDFILE"
    sleep 1
fi
# Headless Codespaces drop the public tunnel when no client is attached.
# Keep a forward open so the URL stays reachable for API and bot clients.
nohup gh codespace ports forward "$HTTP_PORT:$LOCAL_FORWARD_PORT" -c "$CODESPACE_NAME" \
    >"$FORWARD_LOG" 2>&1 &
echo $! > "$FORWARD_PIDFILE"
sleep 8
gh codespace ports visibility "$HTTP_PORT:public" -c "$CODESPACE_NAME"

say "Creating the admin user from .env"
ADMIN_USER_B64=$(printf '%s' "$CANASTA_USER" | base64 -w0)
ADMIN_PASS_B64=$(printf '%s' "$CANASTA_PASS" | base64 -w0)
remote <<EOF
set -euo pipefail
U=\$(printf %s '$ADMIN_USER_B64' | base64 -d)
P=\$(printf %s '$ADMIN_PASS_B64' | base64 -d)
canasta maintenance script -i '$INSTANCE_ID' -w '$WIKI_ID' \
    createAndPromote "\$U" "\$P" --sysop --bureaucrat --interface-admin --force
EOF

say "Creating the bot user from .env"
BOT_USER_B64=$(printf '%s' "$BOT_USER" | base64 -w0)
BOT_PASS_B64=$(printf '%s' "$BOT_PASS" | base64 -w0)
remote <<EOF
set -euo pipefail
U=\$(printf %s '$BOT_USER_B64' | base64 -d)
P=\$(printf %s '$BOT_PASS_B64' | base64 -d)
canasta maintenance script -i '$INSTANCE_ID' -w '$WIKI_ID' \
    createAndPromote "\$U" "\$P" --bot --force
EOF

say "Rebuilding Semantic MediaWiki data"
remote <<EOF
set -euo pipefail
canasta maintenance extension SemanticMediaWiki:rebuildData --id '$INSTANCE_ID'
EOF

say "Verifying public read, blocked anonymous edit, admin login, bot edit, and SMW query"
PUBLIC_URL="https://$WIKI_HOST"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$PUBLIC_URL/wiki/Main_Page")
if [[ "$CODE" != "200" ]]; then
    echo "Main page returned HTTP $CODE from $PUBLIC_URL" >&2
    exit 1
fi

API="$PUBLIC_URL/w/api.php"
COOKIES=$(mktemp)
trap 'rm -f "$COOKIES"' EXIT
TOKEN=$(curl -sS -b "$COOKIES" -c "$COOKIES" "$API?action=query&meta=tokens&type=login&format=json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["query"]["tokens"]["logintoken"])')
LOGIN_RESULT=$(curl -sS -b "$COOKIES" -c "$COOKIES" \
    --data-urlencode 'action=login' \
    --data-urlencode "lgname=$CANASTA_USER" \
    --data-urlencode "lgpassword=$CANASTA_PASS" \
    --data-urlencode "lgtoken=$TOKEN" \
    --data-urlencode 'format=json' "$API" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("login",{}).get("result",""))')
if [[ "$LOGIN_RESULT" != "Success" ]]; then
    echo "Admin login failed: $LOGIN_RESULT" >&2
    exit 1
fi

ANON_COOKIES=$(mktemp)
trap 'rm -f "$COOKIES" "$ANON_COOKIES"' EXIT
ANON_EDIT_RESULT=""
# Codespaces occasionally drops the session cookie, producing badtoken
# instead of permissiondenied. Retry with a fresh session before failing.
for _attempt in 1 2 3; do
    rm -f "$ANON_COOKIES"
    ANON_TOKEN=$(curl -sS -b "$ANON_COOKIES" -c "$ANON_COOKIES" \
        "$API?action=query&meta=tokens&type=csrf&format=json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["query"]["tokens"]["csrftoken"])')
    ANON_EDIT_RESULT=$(curl -sS -b "$ANON_COOKIES" -c "$ANON_COOKIES" \
        --data-urlencode 'action=edit' \
        --data-urlencode 'title=SetupAnonEditShouldFail' \
        --data-urlencode 'text=should not save' \
        --data-urlencode "token=$ANON_TOKEN" \
        --data-urlencode 'format=json' "$API" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",{}).get("code",""))')
    if [[ "$ANON_EDIT_RESULT" != "badtoken" ]]; then
        break
    fi
done
if [[ "$ANON_EDIT_RESULT" != "permissiondenied" ]]; then
    echo "Anonymous edit was not rejected (result: ${ANON_EDIT_RESULT:-success})" >&2
    exit 1
fi

BOT_COOKIES=$(mktemp)
trap 'rm -f "$COOKIES" "$ANON_COOKIES" "$BOT_COOKIES"' EXIT
BOT_LOGIN_RESULT=""
# Retry for the same transient session-cookie problem as anonymous edits.
for _attempt in 1 2 3; do
    rm -f "$BOT_COOKIES"
    BOT_TOKEN=$(curl -sS -b "$BOT_COOKIES" -c "$BOT_COOKIES" "$API?action=query&meta=tokens&type=login&format=json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["query"]["tokens"]["logintoken"])')
    BOT_LOGIN_RESULT=$(curl -sS -b "$BOT_COOKIES" -c "$BOT_COOKIES" \
        --data-urlencode 'action=login' \
        --data-urlencode "lgname=$BOT_USER" \
        --data-urlencode "lgpassword=$BOT_PASS" \
        --data-urlencode "lgtoken=$BOT_TOKEN" \
        --data-urlencode 'format=json' "$API" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("login",{}).get("result",""))')
    if [[ "$BOT_LOGIN_RESULT" == "Success" ]]; then
        break
    fi
done
if [[ "$BOT_LOGIN_RESULT" != "Success" ]]; then
    echo "Bot login failed: $BOT_LOGIN_RESULT" >&2
    exit 1
fi

BOT_GROUPS=$(curl -sS -b "$BOT_COOKIES" -c "$BOT_COOKIES" \
    "$API?action=query&meta=userinfo&uiprop=groups&format=json" \
    | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["query"]["userinfo"]["groups"]))')
if [[ ",$BOT_GROUPS," != *",bot,"* ]]; then
    echo "Bot user is not in the bot group (groups: $BOT_GROUPS)" >&2
    exit 1
fi

BOT_EDIT_RESULT=""
for _attempt in 1 2 3; do
    BOT_CSRF=$(curl -sS -b "$BOT_COOKIES" -c "$BOT_COOKIES" \
        "$API?action=query&meta=tokens&type=csrf&format=json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["query"]["tokens"]["csrftoken"])')
    BOT_EDIT_RESULT=$(curl -sS -b "$BOT_COOKIES" -c "$BOT_COOKIES" \
        --data-urlencode 'action=edit' \
        --data-urlencode 'title=SetupBotEditTest' \
        --data-urlencode 'text=Bot edit test.' \
        --data-urlencode 'bot=1' \
        --data-urlencode "token=$BOT_CSRF" \
        --data-urlencode 'format=json' "$API" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("edit",{}).get("result") or d.get("error",{}).get("code",""))')
    if [[ "$BOT_EDIT_RESULT" != "badtoken" ]]; then
        break
    fi
done
if [[ "$BOT_EDIT_RESULT" != "Success" ]]; then
    echo "Bot edit failed: ${BOT_EDIT_RESULT:-unknown error}" >&2
    exit 1
fi

remote <<EOF
set -euo pipefail
printf 'SMW price test. [[Has price::42]]\n' \
    | docker exec -i '$INSTANCE_ID-web-1' php maintenance/run.php edit --wiki='$WIKI_ID' SmwTest
printf '{{#ask: [[Has price::>0]] |?Has price}}\n' \
    | docker exec -i '$INSTANCE_ID-web-1' php maintenance/run.php edit --wiki='$WIKI_ID' SmwTestQuery
docker exec '$INSTANCE_ID-web-1' php maintenance/run.php runJobs --wiki='$WIKI_ID'
EOF
if ! curl -sS --max-time 30 "$PUBLIC_URL/wiki/SmwTestQuery" | grep -q '>42<'; then
    echo "SMW query did not render the expected value 42" >&2
    exit 1
fi

say "Done"
printf 'Wiki:  %s\n' "$PUBLIC_URL"
printf 'Admin: %s\n' "$CANASTA_USER"
echo "Port $HTTP_PORT is public. Anyone with the URL can read the wiki; anonymous editing is disabled."
echo "Public URL kept alive by port forward pid $(cat "$FORWARD_PIDFILE")."
echo "Stop it with: kill $(cat "$FORWARD_PIDFILE")"
