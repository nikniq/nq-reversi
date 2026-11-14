#!/usr/bin/env bash
# cx.sh — local operations helper for the Reversi app.
# Usage: ./cx.sh <command> [args]   (./cx.sh help for the list)
set -euo pipefail
cd "$(dirname "$0")"

PHP=${PHP:-php}
COMPOSER=${COMPOSER:-composer}
BACKUP_DIR=${BACKUP_DIR:-storage/backups}

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else B= G= Y= R= D= N=; fi
info() { echo "${B}→${N} $*"; }
ok()   { echo "${G}✓${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
die()  { echo "${R}✗${N} $*" >&2; exit 1; }
art()  { $PHP artisan "$@"; }
envval() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'; }

usage() {
  cat <<USAGE
${B}Usage:${N} ./cx.sh <command> [args]

${B}Setup${N}
  setup            Install deps, create .env + key, migrate
  doctor           Check PHP, extensions, .env, permissions, Google OAuth config
  google           Show Google OAuth setup values (redirect URI etc.)

${B}Develop${N}
  serve [port]     Run the dev server (default 8000)
  test [filter]    Run tests (optional --filter)
  routes           List app routes
  tinker           Open Tinker

${B}Database${N}
  migrate          Run migrations
  fresh            Drop all tables and re-migrate (asks first)
  backup           Back up the SQLite database to ${BACKUP_DIR}
  restore [file]   Restore a SQLite backup (latest if omitted)
  users            List registered users

${B}Maintenance${N}
  clear            Clear all caches
  optimize         Build production caches
  perms            Fix storage/ and bootstrap/cache permissions
  down | up        Toggle maintenance mode
  logs [n]         Tail the Laravel log (last n lines, default 100)
  status           App info + git status
USAGE
}

sqlite_path() {
  local db; db=$(envval DB_DATABASE)
  [ "$(envval DB_CONNECTION)" = "sqlite" ] || die "backup/restore only supports SQLite (DB_CONNECTION=$(envval DB_CONNECTION))"
  echo "${db:-database/database.sqlite}"
}

cmd=${1:-help}; shift || true
case "$cmd" in
  setup)
    info "Installing PHP dependencies"; $COMPOSER install --no-interaction
    [ -f .env ] || { cp .env.example .env; ok "Created .env"; }
    [ -n "$(envval APP_KEY)" ] || art key:generate
    if [ "$(envval DB_CONNECTION)" = "sqlite" ]; then db=$(sqlite_path); [ -f "$db" ] || touch "$db"; fi
    art migrate --force
    ok "Setup complete — run ./cx.sh serve"
    ;;

  doctor)
    fail=0
    check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "$1 — $3"; fail=1; fi; }
    check "PHP $($PHP -r 'echo PHP_VERSION;')" "$PHP -r 'exit(version_compare(PHP_VERSION,\"8.3\",\">=\")?0:1);'" "PHP 8.3+ required"
    for ext in pdo_sqlite mbstring openssl curl; do check "ext-$ext" "$PHP -r 'exit(extension_loaded(\"$ext\")?0:1);'" "missing extension"; done
    check ".env present" "[ -f .env ]" "run ./cx.sh setup"
    check "APP_KEY set" "[ -n \"$(envval APP_KEY)\" ]" "run php artisan key:generate"
    check "vendor/ installed" "[ -d vendor ]" "run composer install"
    check "storage writable" "[ -w storage/logs ] && [ -w bootstrap/cache ]" "run ./cx.sh perms"
    check "migrations up to date" "! art migrate:status | grep -q Pending" "run ./cx.sh migrate"
    check "GOOGLE_CLIENT_ID set" "[ -n \"$(envval GOOGLE_CLIENT_ID)\" ]" "Google sign-in disabled (see ./cx.sh google)"
    check "GOOGLE_CLIENT_SECRET set" "[ -n \"$(envval GOOGLE_CLIENT_SECRET)\" ]" "Google sign-in disabled"
    if [ "$(envval APP_ENV)" = "production" ]; then check "APP_DEBUG off in production" "[ \"$(envval APP_DEBUG)\" = false ]" "set APP_DEBUG=false"; fi
    [ $fail -eq 0 ] && ok "All checks passed" || { warn "Some checks need attention"; exit 1; }
    ;;

  google)
    url=$(envval APP_URL); url=${url:-http://localhost:8000}
    cat <<G
${B}Google OAuth setup${N}  (https://console.cloud.google.com/apis/credentials)
  1. Create an OAuth client ID → type "Web application"
  2. Authorized JavaScript origin:  ${G}${url}${N}
  3. Authorized redirect URI:       ${G}${url}/auth/google/callback${N}
  4. Put the values in .env:
       GOOGLE_CLIENT_ID=...
       GOOGLE_CLIENT_SECRET=...
  5. ./cx.sh clear

  Current: client id ${D}$( [ -n "$(envval GOOGLE_CLIENT_ID)" ] && echo set || echo "not set" )${N}, secret ${D}$( [ -n "$(envval GOOGLE_CLIENT_SECRET)" ] && echo set || echo "not set" )${N}
G
    ;;

  serve)   art serve --port="${1:-${PORT:-8000}}" ;;
  test)    if [ $# -gt 0 ]; then art test --filter="$1"; else art test; fi ;;
  routes)  art route:list --except-vendor ;;
  tinker)  art tinker ;;

  migrate) art migrate --force "$@" ;;
  fresh)
    [ "$(envval APP_ENV)" = "production" ] && die "Refusing to run fresh in production"
    read -r -p "Drop ALL tables and re-migrate? [y/N] " a; [ "$a" = y ] || exit 0
    "$0" backup || true
    art migrate:fresh --force
    ;;
  backup)
    db=$(sqlite_path); [ -f "$db" ] || die "No database at $db"
    mkdir -p "$BACKUP_DIR"
    out="$BACKUP_DIR/db-$(date +%Y%m%d-%H%M%S).sqlite"
    if command -v sqlite3 >/dev/null; then sqlite3 "$db" ".backup '$out'"; else cp "$db" "$out"; fi
    gzip "$out"; ok "Backup: $out.gz"
    ls -1t "$BACKUP_DIR"/db-*.sqlite.gz | tail -n +11 | xargs -r rm -f   # keep last 10
    ;;
  restore)
    db=$(sqlite_path)
    f=${1:-$(ls -1t "$BACKUP_DIR"/db-*.sqlite.gz 2>/dev/null | head -1)}
    [ -n "$f" ] && [ -f "$f" ] || die "No backup found"
    read -r -p "Restore $f over $db? [y/N] " a; [ "$a" = y ] || exit 0
    gunzip -c "$f" > "$db"; ok "Restored $f"
    ;;
  users)
    art tinker --execute='App\Models\User::query()->latest()->limit(50)->get(["id","name","email","google_id","created_at"])->each(fn($u)=>printf("%4d  %-24s %-32s %-7s %s\n",$u->id,$u->name,$u->email,$u->google_id?"google":"email",$u->created_at));'
    ;;

  clear)    art optimize:clear ;;
  optimize) art optimize ;;
  perms)    chmod -R ug+rwX storage bootstrap/cache; ok "Permissions fixed" ;;
  down)     art down --refresh=15 "$@" ;;
  up)       art up ;;
  logs)     f=storage/logs/laravel.log; [ -f "$f" ] || die "No log yet"; tail -n "${1:-100}" -f "$f" ;;
  status)   art about --only=environment,drivers; git status -sb; git log --oneline -5 ;;

  help|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
