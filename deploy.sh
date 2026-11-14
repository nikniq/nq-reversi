#!/usr/bin/env bash
# deploy.sh — deploy the Reversi app to a server over SSH (git-based).
#
# Config: environment variables or a git-ignored .deploy.env file
#   DEPLOY_HOST     user@host                         (required)
#   DEPLOY_PATH     app directory on the server        (required)
#   DEPLOY_BRANCH   branch to deploy                   (default: main)
#   DEPLOY_PORT     SSH port                           (default: 22)
#   DEPLOY_PHP      php binary on server               (default: php)
#   DEPLOY_COMPOSER composer binary on server          (default: composer)
#   DEPLOY_URL      public URL for the health check    (optional, e.g. https://reversi.example.com)
#
# The server directory must be a clone of this repo. On shared hosting, point
# the domain's document root at $DEPLOY_PATH/public_html.
#
# Usage:
#   ./deploy.sh [deploy]   Test, push, deploy, health-check (auto-rollback on failure)
#   ./deploy.sh init       First-time server setup (clone, .env, key, migrate)
#   ./deploy.sh rollback   Roll back to the previously deployed commit
#   ./deploy.sh status     Show deployed commit vs local
#   ./deploy.sh logs [n]   Tail the server's Laravel log
#   ./deploy.sh ssh        Open a shell in the app directory
#   ./deploy.sh artisan …  Run an artisan command on the server
#   Flags: --dry-run (print remote script), --skip-tests, --force (allow dirty tree)
set -euo pipefail
cd "$(dirname "$0")"
[ -f .deploy.env ] && source .deploy.env

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
info() { echo "${B}→${N} $*"; }
ok()   { echo "${G}✓${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
die()  { echo "${R}✗${N} $*" >&2; exit 1; }

DRY=0 SKIP_TESTS=0 FORCE=0 ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;; --skip-tests) SKIP_TESTS=1 ;; --force) FORCE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
CMD=${1:-deploy}; shift || true

: "${DEPLOY_HOST:?Set DEPLOY_HOST (user@host) in env or .deploy.env}"
: "${DEPLOY_PATH:?Set DEPLOY_PATH (app directory on server) in env or .deploy.env}"
BRANCH=${DEPLOY_BRANCH:-main}
PORT=${DEPLOY_PORT:-22}
RPHP=${DEPLOY_PHP:-php}
RCOMPOSER=${DEPLOY_COMPOSER:-composer}
REPO=$(git remote get-url origin)

remote() {  # run a bash script (stdin) on the server
  local script; script=$(cat)
  if [ $DRY -eq 1 ]; then echo "${B}# ssh -p $PORT $DEPLOY_HOST${N}"; echo "$script"; return 0; fi
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
    info "Deploying ${B}$(git rev-parse --short "$BRANCH")${N} to $DEPLOY_HOST:$DEPLOY_PATH"
    remote <<SCRIPT
cd "$DEPLOY_PATH"
git rev-parse HEAD > .deploy_previous
[ -f database/database.sqlite ] && mkdir -p storage/backups && cp database/database.sqlite "storage/backups/pre-deploy-\$(date +%Y%m%d-%H%M%S).sqlite" || true
ls -1t storage/backups/pre-deploy-* 2>/dev/null | tail -n +6 | xargs -r rm -f
$RPHP artisan down --refresh=15 --retry=60 || true
trap '$RPHP artisan up' EXIT
git fetch -q origin "$BRANCH"
git reset -q --hard "origin/$BRANCH"
$RCOMPOSER install --no-dev --optimize-autoloader --no-interaction --quiet
if grep -q '^DB_CONNECTION=sqlite' .env 2>/dev/null; then [ -f database/database.sqlite ] || touch database/database.sqlite; fi
$RPHP artisan migrate --force
$RPHP artisan optimize:clear >/dev/null
$RPHP artisan optimize
chmod -R ug+rwX storage bootstrap/cache
echo "Deployed \$(git rev-parse --short HEAD) (previous \$(cut -c1-7 .deploy_previous))"
SCRIPT
    if ! health_check; then
      warn "Rolling back"; "$0" rollback; die "Deploy failed health check and was rolled back"
    fi
    ok "Deploy complete"
    ;;

  init)
    info "Initialising $DEPLOY_HOST:$DEPLOY_PATH from $REPO"
    remote <<SCRIPT
if [ ! -d "$DEPLOY_PATH/.git" ]; then git clone -q -b "$BRANCH" "$REPO" "$DEPLOY_PATH"; fi
cd "$DEPLOY_PATH"
$RCOMPOSER install --no-dev --optimize-autoloader --no-interaction --quiet
if [ ! -f .env ]; then
  cp .env.example .env
  sed -i.bak -e 's/^APP_ENV=.*/APP_ENV=production/' -e 's/^APP_DEBUG=.*/APP_DEBUG=false/' .env && rm -f .env.bak
  $RPHP artisan key:generate --force
fi
[ -f database/database.sqlite ] || touch database/database.sqlite
$RPHP artisan migrate --force
$RPHP artisan optimize
chmod -R ug+rwX storage bootstrap/cache
echo "Initialised. Now edit $DEPLOY_PATH/.env (APP_URL, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET) and run: ./deploy.sh artisan optimize"
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
    echo "Local  $BRANCH: $(git log -1 --format='%h %s' "$BRANCH")"
    remote <<SCRIPT
cd "$DEPLOY_PATH"; echo "Server       : \$(git log -1 --format='%h %s (%cr)')"
$RPHP artisan about --only=environment | sed -n '1,8p'
SCRIPT
    ;;

  logs)     remote <<<"tail -n ${1:-100} \"$DEPLOY_PATH/storage/logs/laravel.log\"" ;;
  ssh)      exec ssh -t -p "$PORT" "$DEPLOY_HOST" "cd \"$DEPLOY_PATH\" && exec \$SHELL -l" ;;
  artisan)  remote <<<"cd \"$DEPLOY_PATH\" && $RPHP artisan $(printf '%q ' "$@")" ;;

  *) die "Unknown command: $CMD (deploy|init|rollback|status|logs|ssh|artisan)" ;;
esac
