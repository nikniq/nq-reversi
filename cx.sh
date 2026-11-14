#!/usr/bin/env bash
# cx.sh — day-to-day operations helper for the Reversi app.
# Usage: ./cx.sh <command>
set -euo pipefail
cd "$(dirname "$0")"

PHP=${PHP:-php}
COMPOSER=${COMPOSER:-composer}

usage() {
  cat <<USAGE
Usage: ./cx.sh <command>

  setup      Install deps, create .env, generate key, migrate
  serve      Run the local dev server (PORT env, default 8000)
  clear      Clear all Laravel caches (config, route, view, event, app)
  optimize   Build production caches (config, route, view, event)
  migrate    Run database migrations (--force)
  test       Run the test suite
  perms      Fix storage/ and bootstrap/cache permissions
  down       Put the app into maintenance mode
  up         Bring the app out of maintenance mode
  logs       Tail the Laravel log
  status     Show app info and git status
USAGE
}

cmd=${1:-help}; shift || true
case "$cmd" in
  setup)
    $COMPOSER install --no-interaction
    [ -f .env ] || cp .env.example .env
    grep -q '^APP_KEY=base64' .env || $PHP artisan key:generate
    [ -f database/database.sqlite ] || touch database/database.sqlite
    $PHP artisan migrate --force
    ;;
  serve)    $PHP artisan serve --port="${PORT:-8000}" "$@" ;;
  clear)    $PHP artisan optimize:clear ;;
  optimize) $PHP artisan optimize ;;
  migrate)  $PHP artisan migrate --force "$@" ;;
  test)     $PHP artisan test "$@" ;;
  perms)
    chmod -R ug+rwX storage bootstrap/cache
    ;;
  down)     $PHP artisan down --refresh=15 "$@" ;;
  up)       $PHP artisan up ;;
  logs)     tail -n 100 -f storage/logs/laravel.log ;;
  status)   $PHP artisan about --only=environment; git status -sb ;;
  help|-h|--help) usage ;;
  *) echo "Unknown command: $cmd"; usage; exit 1 ;;
esac
