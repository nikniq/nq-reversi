#!/usr/bin/env bash
# deploy.sh — deploy the Reversi app to a server over SSH (git-based).
#
# Config: environment variables or a git-ignored .deploy.env file
#   DEPLOY_HOST     user@host — leave unset to run ON the server itself
#   DEPLOY_PATH     app directory on the server        (default in server mode: this dir)
#   DEPLOY_BRANCH   branch to deploy                   (default: main)
#   DEPLOY_PORT     SSH port                           (default: 22)
#   DEPLOY_PHP      php binary on server               (default: php)
#   DEPLOY_COMPOSER composer binary on server          (default: composer)
#   DEPLOY_URL      public URL for the health check    (optional, e.g. https://reversi.example.com)
#
# The server directory must be a clone of this repo. On shared hosting, point
# the domain's document root at $DEPLOY_PATH/public_html.
#
# Two ways to run:
#   From your machine:  set DEPLOY_HOST + DEPLOY_PATH; tests run locally, then SSH deploys.
#   On the server:      just run ./deploy.sh in the app dir; it pulls origin/$BRANCH in place.
#
# Usage:
#   ./deploy.sh [deploy]   Test, push, deploy, health-check (auto-rollback on failure)
#   ./deploy.sh init       First-time server setup (clone, .env, key, migrate)
#   ./deploy.sh rollback   Roll back to the previously deployed commit
#   ./deploy.sh status     Show deployed commit vs local
#   ./deploy.sh logs [n]   Tail the server's Laravel log
#   ./deploy.sh ssh        Open a shell in the app directory
#   ./deploy.sh artisan …  Run an artisan command on the server
#   ./deploy.sh check      Run the pre-deploy checks on the server (also: doctor, backup)
#   ./deploy.sh cx …       Run any ./cx.sh command on the server
#   Flags: --dry-run (print remote script), --skip-tests, --force (allow dirty tree),
#          --no-backup (skip the pre-deploy DB backup)
#
# Deploy steps: maintenance on → update code → composer → checks (.env, APP_KEY,
# DB reachable, APP_DEBUG off) → DB backup → migrate → cache → maintenance off.
# Any failure reverts the code to the previous commit and brings the site back up.
set -euo pipefail
APP_DIR=${DEPLOY_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}
# Bash reads scripts lazily, and a deploy rewrites this file via git. Run from a
# temporary copy so the update can't corrupt the running script.
if [ -z "${DEPLOY_APP_DIR:-}" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/deploy.XXXXXX"); cp "$0" "$tmp"
  DEPLOY_APP_DIR="$APP_DIR" DEPLOY_SELF="$0" bash "$tmp" "$@" && rc=0 || rc=$?; rm -f "$tmp"; exit $rc
fi
cd "$APP_DIR"
[ -f .deploy.env ] && source .deploy.env

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
info() { echo "${B}→${N} $*"; }
ok()   { echo "${G}✓${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
die()  { echo "${R}✗${N} $*" >&2; exit 1; }

DRY=0 SKIP_TESTS=0 FORCE=0 NO_BACKUP=0 ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;; --skip-tests) SKIP_TESTS=1 ;; --force) FORCE=1 ;; --no-backup) NO_BACKUP=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
CMD=${1:-deploy}; shift || true

if [ -z "${DEPLOY_HOST:-}" ]; then
  LOCAL=1; DEPLOY_PATH=${DEPLOY_PATH:-$PWD}; TARGET="this server ($DEPLOY_PATH)"
else
  LOCAL=0; : "${DEPLOY_PATH:?Set DEPLOY_PATH (app directory on server) in env or .deploy.env}"
  TARGET="$DEPLOY_HOST:$DEPLOY_PATH"
fi
BRANCH=${DEPLOY_BRANCH:-main}
PORT=${DEPLOY_PORT:-22}
RPHP=${DEPLOY_PHP:-php}
RCOMPOSER=${DEPLOY_COMPOSER:-composer}
REPO=$(git remote get-url origin)

remote() {  # run a bash script (stdin) on the server
  local script; script=$(cat)
  if [ $DRY -eq 1 ]; then echo "${B}# target: $TARGET${N}"; echo "$script"; return 0; fi
  if [ $LOCAL -eq 1 ]; then bash -s <<<"set -euo pipefail; $script"; return; fi
  ssh -p "$PORT" "$DEPLOY_HOST" "bash -s" <<<"set -euo pipefail; $script"
}

health_check() {
  [ -n "${DEPLOY_URL:-}" ] || { warn "DEPLOY_URL not set — skipping health check"; return 0; }
  [ $DRY -eq 1 ] && return 0
  info "Health check ${DEPLOY_URL}/up"
  for i in 1 2 3 4 5; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${DEPLOY_URL%/}/up" || true)
    [ "$code" = 200 ] && { ok "Healthy (HTTP 200)"; return 0; }
    sleep 3
  done
  warn "Health check failed (last HTTP $code)"; return 1
}

preflight() {
  if [ $LOCAL -eq 1 ]; then
    # On the server: no dev deps/tests here, and code comes from origin.
    if [ $FORCE -eq 0 ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
      die "Server has modified tracked files (they'd be overwritten). Inspect with git status, or pass --force"
    fi
    return 0
  fi
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || warn "Local branch is not $BRANCH (deploying origin/$BRANCH)"
  if [ $FORCE -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
    die "Working tree has uncommitted changes (commit them or pass --force)"
  fi
  if [ $SKIP_TESTS -eq 0 ]; then info "Running tests"; php artisan test --compact || die "Tests failed — aborting"; fi
  info "Pushing $BRANCH to origin"; [ $DRY -eq 1 ] || git push -q origin "$BRANCH"
}

case "$CMD" in
  deploy)
    preflight
    [ $LOCAL -eq 1 ] && git fetch -q origin "$BRANCH"
    info "Deploying ${B}$(git rev-parse --short "origin/$BRANCH")${N} to $TARGET"
    remote <<SCRIPT
cd "$DEPLOY_PATH"
export PHP="$RPHP" COMPOSER="$RCOMPOSER" YES=1
step() { echo "  · \$*"; }
prev=\$(git rev-parse HEAD)
echo "\$prev" > .deploy_previous

[ -f .env ] || { echo "✗ No .env on server — run ./deploy.sh init first"; exit 1; }
git fetch -q origin "$BRANCH"
new=\$(git rev-parse "origin/$BRANCH")
if [ "\$prev" = "\$new" ]; then step "Already at \${new:0:7} — redeploying"; fi

step "Maintenance mode on"
\$PHP artisan down --refresh=15 --retry=60 >/dev/null || true
trap '\$PHP artisan up >/dev/null; echo "  · Maintenance mode off"' EXIT

revert() {
  echo "✗ \$1 — reverting code to \${prev:0:7}"
  git reset -q --hard "\$prev"
  \$COMPOSER install --no-dev --optimize-autoloader --no-interaction --quiet || true
  \$PHP artisan optimize >/dev/null 2>&1 || true
  exit 1
}

step "Updating code \${prev:0:7} → \${new:0:7}"
git reset -q --hard "\$new"
step "Installing dependencies"
\$COMPOSER install --no-dev --optimize-autoloader --no-interaction --quiet || revert "composer install failed"
\$PHP artisan optimize:clear >/dev/null || true
if grep -q '^DB_CONNECTION=sqlite' .env; then [ -f database/database.sqlite ] || touch database/database.sqlite; fi
./cx.sh perms >/dev/null

step "Pre-deploy checks"
./cx.sh check | sed 's/^/      /' || revert "pre-deploy checks failed (fix .env/DB on the server)"

if [ "$NO_BACKUP" != 1 ]; then
  step "Backing up database"
  ./cx.sh backup pre-deploy | sed 's/^/      /' || revert "database backup failed (use --no-backup to skip)"
fi

step "Migrating"
\$PHP artisan migrate --force || revert "migrations failed (DB backup is in storage/backups)"
step "Caching config/routes/views"
\$PHP artisan optimize >/dev/null || revert "optimize failed"
echo "✓ Deployed \${new:0:7} (previous \${prev:0:7})"
SCRIPT
    if ! health_check; then
      warn "Rolling back"; "$DEPLOY_SELF" rollback; die "Deploy failed health check and was rolled back"
    fi
    ok "Deploy complete"
    ;;

  init)
    info "Initialising $TARGET from $REPO"
    remote <<SCRIPT
if [ ! -d "$DEPLOY_PATH/.git" ]; then git clone -q -b "$BRANCH" "$REPO" "$DEPLOY_PATH"; fi
cd "$DEPLOY_PATH"
export PHP="$RPHP" COMPOSER="$RCOMPOSER" YES=1
\$COMPOSER install --no-dev --optimize-autoloader --no-interaction --quiet
if [ ! -f .env ]; then cp .env.example .env; \$PHP artisan key:generate --force; fi
./cx.sh env:prod
if grep -q '^DB_CONNECTION=sqlite' .env; then [ -f database/database.sqlite ] || touch database/database.sqlite; fi
./cx.sh perms
if ./cx.sh check; then
  \$PHP artisan migrate --force && \$PHP artisan optimize
  echo "✓ Initialised. Next: ./cx.sh google  (set GOOGLE_CLIENT_ID/SECRET), then ./deploy.sh"
else
  echo "! Fix the items above in $DEPLOY_PATH/.env (APP_URL, DB_*), then run ./deploy.sh"
fi
SCRIPT
    ;;

  rollback)
    remote <<SCRIPT
cd "$DEPLOY_PATH"
[ -f .deploy_previous ] || { echo "No previous deploy recorded"; exit 1; }
prev=\$(cat .deploy_previous)
$RPHP artisan down --refresh=15 || true
git reset -q --hard "\$prev"
$RCOMPOSER install --no-dev --optimize-autoloader --no-interaction --quiet
$RPHP artisan optimize
$RPHP artisan up
echo "Rolled back to \$(git rev-parse --short HEAD). Note: migrations were not reverted."
SCRIPT
    ;;

  status)
    [ $LOCAL -eq 1 ] || echo "Local  $BRANCH: $(git log -1 --format='%h %s' "$BRANCH")"
    remote <<SCRIPT
cd "$DEPLOY_PATH"; echo "Server       : \$(git log -1 --format='%h %s (%cr)')"
$RPHP artisan about --only=environment | sed -n '1,8p'
SCRIPT
    ;;

  logs)     remote <<<"tail -n ${1:-100} \"$DEPLOY_PATH/storage/logs/laravel.log\"" ;;
  ssh)      [ $LOCAL -eq 1 ] && die "Already on the server"; exec ssh -t -p "$PORT" "$DEPLOY_HOST" "cd \"$DEPLOY_PATH\" && exec \$SHELL -l" ;;
  cx|check|backup|doctor)
            [ "$CMD" = cx ] || set -- "$CMD" "$@"
            remote <<<"cd \"$DEPLOY_PATH\" && PHP=$RPHP COMPOSER=$RCOMPOSER ./cx.sh $(printf '%q ' "$@")" ;;
  artisan)  remote <<<"cd \"$DEPLOY_PATH\" && $RPHP artisan $(printf '%q ' "$@")" ;;

  *) die "Unknown command: $CMD (deploy|init|rollback|status|logs|ssh|artisan|cx|check|doctor|backup)" ;;
esac
