# Canasta + Semantic MediaWiki on GitHub Codespaces

Throwaway MediaWiki + Semantic MediaWiki (SMW) instance in a GitHub Codespace. Nothing persists after the codespace is deleted.

Canasta is a Docker Compose based MediaWiki distribution; SMW is bundled. GitHub's port proxy terminates TLS and forwards plain HTTP to the Canasta edge on port 8080.

## What you get

- MediaWiki (Canasta's current version) + SMW at a public `https://<codespace>-8080.app.github.dev` URL
- Admin user `WikiSysop` with generated password
- No DNS, no TLS setup, no cloud account
- Free tier: 120 core-hours/month (~60 hours on a 2-core machine), 15 GB-month storage

## Warning

A public forwarded port bypasses GitHub authentication. **Anyone with the URL can read and edit the wiki.** Keep the URL private, or disable anonymous editing (see "Lock down"). Delete the codespace when done.

## 1. Create the codespace

Create an empty private repo (or use this one) and choose **Code -> Codespaces -> Create codespace on main**.

Default machine: 2 core / 8 GB / 32 GB disk. That is enough. The default image includes Docker and Docker Compose.

Verify:

```bash
docker --version
docker compose version
```

If Docker is missing, add `.devcontainer/devcontainer.json` and rebuild the container:

```json
{
  "name": "Canasta SMW test",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
  "features": {
    "ghcr.io/devcontainers/features/docker-in-docker:2": {}
  },
  "hostRequirements": { "cpus": 2, "memory": "8gb", "storage": "32gb" },
  "forwardPorts": [8080]
}
```

## 2. Prepare user and groups

```bash
sudo groupadd -f www-data
sudo usermod -aG docker,www-data "$USER"
```

Open a new terminal so the new group membership applies:

```bash
id
```

## 3. Install the Canasta CLI

```bash
curl -fsSL https://get.canasta.wiki | bash
canasta version
canasta doctor
```

Warnings about optional dependencies are fine.

If the installer cannot write to `/usr/local/bin`, rerun it as `curl -fsSL https://get.canasta.wiki | sudo bash`.

## 4. Build the hostname and env file

```bash
export WIKI_HOST="${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
echo "$WIKI_HOST"
# expect: <codespace-name>-8080.app.github.dev

cat > custom.env <<'EOF'
TLS_MODE=off
HTTP_PORT=8080
EOF
```

`TLS_MODE=off` tells Canasta that a reverse proxy in front of it terminates TLS. GitHub's forwarder speaks plain HTTP to the backend by default, so do not use `TLS_MODE=internal` (self-signed) here.

If you open a new terminal later, re-export `WIKI_HOST` before continuing.

## 5. Create the instance

```bash
canasta create -i smwtest -w wiki -n "$WIKI_HOST" -e custom.env
```

This pulls several GB of images, creates the database, and runs `update.php`. Expect 5-15 minutes on first run. Note the instance directory printed at the end.

Point MediaWiki at the public HTTPS URL. This is required: `canasta create` derives the server URL from the internal port and scheme, not from GitHub's proxy.

```bash
canasta config set MW_SITE_SERVER="https://$WIKI_HOST" --id smwtest
```

`config set` restarts the instance.

## 6. Make the port public

In the **PORTS** tab, right-click port `8080`, choose **Port Visibility -> Public**.

Or from the terminal:

```bash
gh codespace ports visibility 8080:public -c "$CODESPACE_NAME"
```

Open the URL:

```
https://<codespace-name>-8080.app.github.dev
```

## 7. Log in

Read the generated admin password:

```bash
find ~ -maxdepth 3 -name 'admin-password_*' -exec cat {} \;
```

Username: `WikiSysop`.

## 8. Enable Semantic MediaWiki

Change into the instance directory printed by `canasta create`. If you lost it:

```bash
find ~ -maxdepth 4 -path '*smwtest*' -name docker-compose.yml
```

Then write the settings file:

```bash
cat > config/settings/global/SemanticMediaWiki.php <<EOF
<?php
wfLoadExtension( 'SemanticMediaWiki' );
enableSemantics( '$WIKI_HOST' );
EOF

canasta restart
canasta maintenance extension SemanticMediaWiki:rebuildData
```

Canasta initializes the SMW tables automatically on first start after enabling, and stores `smw.json` under `config/smw/`.

## 9. Lock down (optional)

Disable anonymous editing and account creation:

```bash
cat > config/settings/global/security.php <<'EOF'
<?php
$wgGroupPermissions['*']['edit'] = false;
$wgGroupPermissions['*']['createaccount'] = false;
EOF

canasta restart
```

## 10. Verify SMW

Create or edit a page and add:

```wikitext
[[Has price::42]]
```

On a second page, add:

```wikitext
{{#ask: [[Has price::>0]] |?Has price}}
```

A rendered table means the SMW store and job queue are working.

## 11. Tear down

- Stop the codespace when not in use (compute billing stops).
- `canasta stop` first if you want a clean shutdown.
- Delete the codespace when done to release storage and free quota.
- Everything is ephemeral. Copy any pages you want to keep before deleting.

## Troubleshooting

**503 or "no server available" from the edge.** Host header mismatch. Check that `canasta config get MW_SITE_FQDN` equals `$WIKI_HOST` exactly, with no scheme or port. Check containers with `docker ps` and logs with `docker compose logs haproxy` from the instance directory.

**Redirect loop.** `MW_SITE_SERVER` must be the `https://` URL with no port. GitHub's proxy sends `X-Forwarded-Proto: https`.

**`permission denied /var/run/docker.sock`.** Redo the group step, then open a new terminal.

**`canasta doctor` complains about the web server group.** Run `sudo groupadd -f www-data && sudo usermod -aG www-data "$USER"`, then open a new terminal.

**Pull stops mid-way.** The codespace hit its idle timeout. Raise it to 240 minutes in Codespaces settings, or keep the terminal active.

**MySQL fails on `cap_add: SYS_NICE` or `ulimits`.** Nested Docker restriction. Add `docker-compose.override.yml` in the instance directory that drops those keys, then `canasta restart`.

**Do not enable Elasticsearch.** Its memlock and sysctl requirements often fail under nested Docker, and the default SQL store is fine for a test.

## Notes

- No DNS or certificate setup is needed. Unlike a VM deployment, Let's Encrypt is not involved.
- Port 80/443 are not used inside the codespace; everything goes through 8080.
- Canasta's bundled SMW may lag the latest upstream release. Check with `canasta extension list`.

## References

- Canasta quick start: https://canasta.wiki/wiki/Help:Quick_start
- Canasta installation: https://canasta.wiki/wiki/Help:Installation
- Canasta non-standard ports: https://canasta.wiki/wiki/Help:Running_on_non-standard_ports
- Canasta extensions (SMW section): https://canasta.wiki/wiki/Help:Extensions_and_skins
- Codespaces port forwarding: https://docs.github.com/en/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace
- Codespaces billing: https://docs.github.com/en/billing/concepts/product-billing/github-codespaces
