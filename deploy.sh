#!/usr/bin/env bash
# deploy.sh — deploy the Reversi app to a server over SSH.
#
# Config via environment or a local .deploy.env file (git-ignored):
#   DEPLOY_HOST   user@host               (required)
#   DEPLOY_PATH   app dir on server, e.g. /home/user/nq-reversi (required)
#   DEPLOY_BRANCH branch to deploy (default: main)
#   DEPLOY_PORT   SSH port (default: 22)
#   DEPLOY_PHP    php binary on server (default: php)
#
# The server dir must be a clone of this repo. On shared hosting, point the
# domain's document root at $DEPLOY_PATH/public_html (or symlink it).
#
# Usage: ./deploy.sh            deploy
#        ./deploy.sh --dry-run  print what would run
set -euo pipefail
cd "$(dirname "$0")"
[ -f .deploy.env ] && source .deploy.env

: "${DEPLOY_HOST:?Set DEPLOY_HOST (user@host)}"
: "${DEPLOY_PATH:?Set DEPLOY_PATH (app directory on server)}"
BRANCH=${DEPLOY_BRANCH:-main}
PORT=${DEPLOY_PORT:-22}
RPHP=${DEPLOY_PHP:-php}

echo "→ Running tests locally"
php artisan test

echo "→ Pushing $BRANCH to origin"
git push origin "$BRANCH"

REMOTE=$(cat <<SCRIPT
set -e
cd "$DEPLOY_PATH"
$RPHP artisan down --refresh=15 || true
git fetch --quiet origin
git checkout --quiet "$BRANCH"
git reset --hard "origin/$BRANCH"
composer install --no-dev --optimize-autoloader --no-interaction
[ -f .env ] || { cp .env.example .env; $RPHP artisan key:generate --force; }
$RPHP artisan migrate --force
$RPHP artisan optimize:clear
$RPHP artisan optimize
chmod -R ug+rwX storage bootstrap/cache
$RPHP artisan up
echo "Deployed \$(git rev-parse --short HEAD)"
SCRIPT
)

if [ "${1:-}" = "--dry-run" ]; then
  echo "ssh -p $PORT $DEPLOY_HOST <<"; echo "$REMOTE"; exit 0
fi

echo "→ Deploying to $DEPLOY_HOST:$DEPLOY_PATH"
ssh -p "$PORT" "$DEPLOY_HOST" "bash -s" <<<"$REMOTE"
echo "✓ Done"
