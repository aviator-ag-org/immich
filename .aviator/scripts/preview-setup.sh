#!/usr/bin/env bash
#
# Aviator Verify preview setup for Immich.
#
# Runs inside the sandbox after Aviator has cleaned /code with
# `git reset --hard && git clean -fd` and checked out the branch under review.
# PREVIEW_URL is injected; account secrets arrive as environment variables.
# Timeout is 1800s and a non-zero exit fails the preview, so every step here
# either succeeds or exits loudly. Nothing falls back to a degraded preview:
# a preview that looks up but is quietly wrong is worse than no preview.
#
# Immich is two processes. Port 3000 (vite dev) is the only public one; it
# proxies /api, /.well-known/immich and /custom.css to the NestJS API on 2283
# with ws:true (web/vite.config.ts:11-20), so a single port carries UI, API and
# websockets, and both web-side and server-side changes get exercised.
#
set -euo pipefail

# =============================================================================
# Adapt these four.
# =============================================================================
APP_DIR="/code"
APP_PORT=3000
HEALTH_URL="http://127.0.0.1:3000/"
INSTALL_CMD="pnpm install --frozen-lockfile --filter=immich... --filter=immich-web..."
# =============================================================================

API_PORT=2283
API_BASE="http://127.0.0.1:${API_PORT}"
LOG_DIR="/preview-logs"          # outside /code, so `git clean -fd` cannot eat it
PGBIN="/usr/lib/postgresql/17/bin"  # outside e2b's forced PATH -- absolute always
PGDATA="/var/lib/postgresql/data"
DEPS_STAMP="/preview-deps-stamp"

# World-writable because postgres drops privileges to the `postgres` user and
# still has to write its log in here.
mkdir -p "$LOG_DIR"
chmod 777 "$LOG_DIR"

log()  { printf '\n=== %s\n' "$*"; }
warn() { printf '\n--- WARNING: %s\n' "$*"; }

dump() {
  local file="$1" lines="${2:-100}"
  if [ -f "$file" ]; then
    printf '\n--- last %s lines of %s ---\n' "$lines" "$file"
    tail -n "$lines" "$file"
    printf -- '--- end %s ---\n' "$file"
  else
    printf '\n--- %s does not exist ---\n' "$file"
  fi
}

die() {
  printf '\nPREVIEW SETUP FAILED: %s\n' "$*" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Runtime configuration
# -----------------------------------------------------------------------------
# IMMICH_HOST=0.0.0.0 is belt-and-braces: config.repository.ts:260 leaves host
# undefined and app.common.ts:88 then calls app.listen(port), which already
# binds all interfaces. Being explicit costs nothing and a loopback-only API
# would look perfectly healthy in these logs while being unreachable.
# development, not production, on purpose. isDev() has exactly three call sites:
# CORS (irrelevant -- the web app is same-origin through the proxy), the OpenAPI
# spec write, and database.repository.ts:507 allowUnorderedMigrations. That last
# one is why: a PR branched off an older main can carry a migration whose
# timestamp sorts before ones already applied, and tolerating that is what keeps
# previews working on arbitrary branches. The cost is that booting rewrites the
# tracked open-api/immich-openapi-specs.json (app.common.ts:68 ->
# misc.ts useSwagger, relative to cwd), leaving the tree dirty for the life of
# the sandbox. `git reset --hard` at the next launch reverts it.
export IMMICH_ENV=development
export IMMICH_HOST=0.0.0.0
export IMMICH_PORT="${API_PORT}"
export IMMICH_MEDIA_LOCATION=/preview-media
export IMMICH_IGNORE_MOUNT_CHECK_ERRORS=true
# config.ts:295 reads this straight off process.env to seed the system default,
# so it disables ML without an API call and without pinning a config file (which
# would make those settings read-only in the admin UI).
export IMMICH_MACHINE_LEARNING_ENABLED=false
export IMMICH_LOG_LEVEL=log
export NO_COLOR=1

export DB_HOSTNAME=127.0.0.1
export DB_PORT=5432
export DB_USERNAME=postgres
export DB_PASSWORD=postgres
export DB_DATABASE_NAME=immich
# pgvector 0.8.x from the image satisfies VECTOR_VERSION_RANGE '>=0.5 <1'
# (server/src/constants.ts:25). Set explicitly rather than relying on the
# auto-detect in database.repository.ts:30, which prefers VectorChord.
export DB_VECTOR_EXTENSION=pgvector

export REDIS_HOSTNAME=127.0.0.1
export REDIS_PORT=6379

# THE mandatory one. web/vite.config.ts:9 otherwise proxies to the compose DNS
# name http://immich-server:2283/, which does not resolve in a single sandbox --
# the web server would come up healthy on 3000 and every API call would fail.
export IMMICH_SERVER_URL="${API_BASE}"

# pnpm store lives outside /code; also exported so pnpm honours it even if the
# global npmrc is ever missing.
export npm_config_store_dir=/pnpm-store

# Aviator account secrets: immich_username / immich_password.
#
# immich_username must hold an EMAIL ADDRESS. Immich authenticates by email --
# auth.dto.ts:68 SignUpSchema extends LoginCredentialSchema, whose email field is
# validation.ts:127 toEmail, i.e. z.email(). A bare username like "admin" is
# rejected with a 400, and the seed below fails loudly rather than limping on.
#
# The uppercase spellings are accepted as a fallback because some secret stores
# normalise key case, and shell variables are case-sensitive -- a mismatch would
# otherwise surface as a baffling 401 at login instead of a clear error.
SEED_EMAIL="${immich_username:-${IMMICH_USERNAME:-admin@immich.cloud}}"
SEED_PASSWORD="${immich_password:-${IMMICH_PASSWORD:-password}}"
export SEED_EMAIL SEED_PASSWORD

log "Preview setup starting"
printf 'branch commit : %s\n' "$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
printf 'image commit  : %s\n' "$(cat /preview-image-sha 2>/dev/null || echo unknown)"
printf 'PREVIEW_URL   : %s\n' "${PREVIEW_URL:-<unset>}"

# -----------------------------------------------------------------------------
# Backing services
# -----------------------------------------------------------------------------
log "Starting postgres"
mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql
if ! su postgres -c "${PGBIN}/pg_ctl -D ${PGDATA} -l ${LOG_DIR}/postgres.log -w start"; then
  dump "${LOG_DIR}/postgres.log"
  die "postgres failed to start"
fi
su postgres -c "${PGBIN}/pg_isready -q" || { dump "${LOG_DIR}/postgres.log"; die "postgres not accepting connections"; }

log "Starting redis"
redis-server --daemonize yes --bind 127.0.0.1 --port 6379 \
  --save '' --appendonly no --dir "$LOG_DIR" --logfile "${LOG_DIR}/redis.log" \
  || { dump "${LOG_DIR}/redis.log"; die "redis failed to start"; }
redis-cli ping >/dev/null 2>&1 || { dump "${LOG_DIR}/redis.log"; die "redis not responding to PING"; }

# -----------------------------------------------------------------------------
# Dependencies
#
# The gate stays: pnpm install is not incremental, so paying it on every launch
# would cost minutes for nothing. It reinstalls only when the lockfile hash moved
# or when a store the image baked has gone missing.
#
# The missing-store checks are defensive rather than expected. `git clean -fd`
# leaves node_modules alone (git does not remove an untracked directory whose
# entries are all ignored, and `**/node_modules/**` ignores all of them), so in
# normal operation only a lockfile change triggers a reinstall. The checks exist
# so that a hand-cleaned sandbox or a future `-x` recovers instead of failing
# with thousands of dangling symlinks.
# -----------------------------------------------------------------------------
cd "$APP_DIR"
LOCK_HASH="$(sha256sum "${APP_DIR}/pnpm-lock.yaml" | cut -d' ' -f1)"
BAKED_HASH="$(cat "$DEPS_STAMP" 2>/dev/null || true)"

if [ ! -d "${APP_DIR}/node_modules" ] \
  || [ ! -d "${APP_DIR}/packages/sdk/node_modules" ] \
  || [ ! -d "${APP_DIR}/server/node_modules" ] \
  || [ ! -d "${APP_DIR}/web/node_modules" ] \
  || [ "$BAKED_HASH" != "$LOCK_HASH" ]; then
  log "Installing dependencies (lockfile changed, or a baked store is missing)"
  eval "$INSTALL_CMD" || die "dependency install failed"
  printf '%s\n' "$LOCK_HASH" > "$DEPS_STAMP"
else
  log "Dependencies unchanged since image build -- skipping install"
fi

# -----------------------------------------------------------------------------
# Build from branch source
#
# server/dist and web/build are deliberately absent from the image: both are
# gitignored, so a baked copy would survive the launch clean and serve the
# image's code instead of the branch's.
#
# web/.svelte-kit is the exception -- it IS baked, because web's `prepare` script
# runs svelte-kit sync during the image's pnpm install, and it is gitignored so
# it survives the clean. That is why the sync below is unconditional rather than
# skipped when the directory already exists: it regenerates the branch's types
# over the image's.
# -----------------------------------------------------------------------------
# Both are workspace:* packages that resolve to build output, not source, so the
# server and web cannot compile until they exist. Order matters: @immich/sdk
# first, since @immich/plugin-sdk builds against it.
#
# This mirrors the root mise `plugins` task minus @immich/plugin-core, which is
# deliberately skipped: it compiles to wasm via the extism js-pdk toolchain, and
# its only consumer imports it through
# workflow-execution.service.ts:214 importFolder(), which swallows a missing
# folder in a bare catch. Not worth dragging extism into the image.
log "Building @immich/sdk (web imports it as workspace:*)"
pnpm --filter @immich/sdk build || die "@immich/sdk build failed"

log "Building @immich/plugin-sdk (server imports its types)"
pnpm --filter @immich/plugin-sdk build || die "@immich/plugin-sdk build failed"

log "Syncing SvelteKit types"
pnpm --filter immich-web exec svelte-kit sync || die "svelte-kit sync failed"

# nest-cli.json sets deleteOutDir:false, so a source file deleted on this branch
# would otherwise leave a stale .js behind in dist.
log "Building server"
rm -rf "${APP_DIR}/server/dist"
pnpm --filter immich exec nest build || die "server build failed"

# -----------------------------------------------------------------------------
# Launch
# -----------------------------------------------------------------------------
log "Starting API on ${API_PORT}"
cd "${APP_DIR}/server"
nohup node dist/main.js > "${LOG_DIR}/api.log" 2>&1 < /dev/null &
API_PID=$!

# First boot runs migrations and imports 55MB of geodata from /build/geodata,
# so this window is generous on purpose.
log "Waiting for API (migrations + geodata import)"
API_UP=0
for _ in $(seq 1 300); do
  if ! kill -0 "$API_PID" 2>/dev/null; then
    dump "${LOG_DIR}/api.log" 150
    die "API process exited during startup"
  fi
  # -fs, not -fsS: a connection refused is the expected state while the server
  # boots, and -S would print one scary error line every 2 seconds into the
  # output Aviator shows on failure.
  if curl -fs -o /dev/null "${API_BASE}/api/server/ping"; then API_UP=1; break; fi
  sleep 2
done
[ "$API_UP" = 1 ] || { dump "${LOG_DIR}/api.log" 150; die "API did not answer /api/server/ping within 600s"; }
log "API is up"

log "Starting web on ${APP_PORT}"
cd "${APP_DIR}/web"
nohup pnpm exec vite dev --host 0.0.0.0 --port "${APP_PORT}" \
  > "${LOG_DIR}/web.log" 2>&1 < /dev/null &
WEB_PID=$!

log "Waiting for web"
WEB_UP=0
for _ in $(seq 1 180); do
  if ! kill -0 "$WEB_PID" 2>/dev/null; then
    dump "${LOG_DIR}/web.log" 150
    die "web process exited during startup"
  fi
  if curl -fs -o /dev/null "$HEALTH_URL"; then WEB_UP=1; break; fi
  sleep 2
done
[ "$WEB_UP" = 1 ] || { dump "${LOG_DIR}/web.log" 150; die "web did not answer ${HEALTH_URL} within 360s"; }
log "Web is up"

# Prove the proxy hop works. Vite answering on 3000 says nothing about whether
# /api reaches the NestJS process -- that is the failure this catches.
log "Verifying /api proxy through the public port"
curl -fsS -o /dev/null "http://127.0.0.1:${APP_PORT}/api/server/ping" \
  || { dump "${LOG_DIR}/web.log" 80; die "/api does not proxy from ${APP_PORT} to ${API_PORT}"; }

# -----------------------------------------------------------------------------
# Seed
#
# Immich is unusable empty: a fresh instance shows a registration wizard, then an
# onboarding wizard, then a blank timeline. This mirrors what immich's own e2e
# suite does in e2e/src/utils.ts:307-318. Written outside /code so it does not
# dirty the tree; uses only node built-ins (global fetch/FormData/Blob).
# -----------------------------------------------------------------------------
log "Seeding admin, onboarding and assets"
cat > /preview-seed.mjs <<'SEED_EOF'
import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';

const API = process.env.PREVIEW_API_BASE;
const EMAIL = process.env.SEED_EMAIL;
const PASSWORD = process.env.SEED_PASSWORD;

// Fail here, with the reason, rather than letting a malformed address surface as
// a 400 on sign-up that looks identical to "an admin already exists".
if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(EMAIL ?? '')) {
  throw new Error(
    `the immich_username secret must be an email address (Immich authenticates by email, not username); got ${JSON.stringify(EMAIL)}`,
  );
}
if (!PASSWORD) {
  throw new Error('the immich_password secret is empty');
}
const PUBLIC_URL = process.env.PREVIEW_URL ?? '';
const REPO = '/code';

// Tracked files, so `git reset --hard` restores them on every launch and the
// seed never depends on the e2e/test-assets submodule (which is not cloned).
const ASSETS = [
  ['design/immich-logo-stacked-light.png', '2026-08-09T09:12:00.000Z'],
  ['design/immich-logo-stacked-dark.png', '2026-08-09T14:41:00.000Z'],
  ['design/immich-logo-inline-light.png', '2026-08-10T11:05:00.000Z'],
  ['design/immich-logo-inline-dark.png', '2026-08-10T18:23:00.000Z'],
  ['design/immich-screenshots.png', '2026-08-11T08:30:00.000Z'],
  ['web/static/feature-panel.png', '2026-08-12T16:47:00.000Z'],
];

async function call(path, { method = 'GET', token, json, body } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (json !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fetch(`${API}${path}`, {
    method,
    headers,
    body: json === undefined ? body : JSON.stringify(json),
  });
  const text = await res.text();
  let parsed = text;
  try {
    parsed = text ? JSON.parse(text) : undefined;
  } catch {
    /* leave as text */
  }
  return { ok: res.ok, status: res.status, body: parsed };
}

function fail(step, res) {
  throw new Error(`${step} failed (HTTP ${res.status}): ${JSON.stringify(res.body)}`);
}

const signup = await call('/auth/admin-sign-up', {
  method: 'POST',
  json: { email: EMAIL, password: PASSWORD, name: 'Immich Admin' },
});
if (signup.ok) {
  console.log('created admin user');
} else if (signup.status === 400 && /already has an admin/i.test(JSON.stringify(signup.body ?? ''))) {
  // Re-running setup in an existing sandbox; the admin already exists.
  console.log('admin user already exists');
} else {
  // Any other 400 is a real problem (bad credentials, setup disabled) and must
  // not be swallowed -- otherwise it resurfaces as an unexplained 401 at login.
  fail('admin sign-up', signup);
}

const auth = await call('/auth/login', {
  method: 'POST',
  json: { email: EMAIL, password: PASSWORD },
});
if (!auth.ok) fail('login', auth);
const token = auth.body.accessToken;
console.log('logged in');

// Without this the web app parks every visit on the onboarding wizard.
const onboarding = await call('/system-metadata/admin-onboarding', {
  method: 'POST',
  token,
  json: { isOnboarded: true },
});
if (!onboarding.ok) fail('admin onboarding', onboarding);
console.log('onboarding marked complete');

// PUT /system-config replaces the whole document, so read-modify-write.
// externalDomain is what share links and OAuth redirects are built from -- the
// one place the app genuinely needs to know its own public URL.
const current = await call('/system-config', { token });
if (!current.ok) fail('read system config', current);
const config = current.body;
if (PUBLIC_URL) config.server.externalDomain = PUBLIC_URL;
if (config.machineLearning) config.machineLearning.enabled = false;
const written = await call('/system-config', { method: 'PUT', token, json: config });
if (!written.ok) fail('write system config', written);
console.log(`external domain set to ${PUBLIC_URL || '<unset>'}`);

let uploaded = 0;
let assetId;
for (const [file, when] of ASSETS) {
  const bytes = await readFile(`${REPO}/${file}`);
  const form = new FormData();
  form.set('assetData', new Blob([bytes]), basename(file));
  form.set('fileCreatedAt', when);
  form.set('fileModifiedAt', when);
  form.set('filename', basename(file));
  const res = await fetch(`${API}/assets`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  });
  const parsed = await res.json().catch(() => undefined);
  if (!res.ok) fail(`upload ${file}`, { status: res.status, body: parsed });
  assetId = parsed?.id ?? assetId;
  uploaded += 1;
}
console.log(`uploaded ${uploaded} assets`);

// Thumbnails are generated by a background job. Wait briefly so the first
// screenshot Verify takes shows photos rather than grey placeholders.
if (assetId) {
  for (let i = 0; i < 30; i++) {
    const asset = await call(`/assets/${assetId}`, { token });
    if (asset.ok && asset.body?.thumbhash) {
      console.log('thumbnails generated');
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}
SEED_EOF

PREVIEW_API_BASE="${API_BASE}/api" node /preview-seed.mjs || die "seeding failed"

# -----------------------------------------------------------------------------
log "Preview ready"
printf 'public port : %s\n' "$APP_PORT"
printf 'public url  : %s\n' "${PREVIEW_URL:-<unset>}"
printf 'sign in as  : %s\n' "$SEED_EMAIL"
printf 'logs        : %s/{api,web,postgres,redis}.log\n' "$LOG_DIR"
