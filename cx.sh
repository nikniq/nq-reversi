#!/usr/bin/env bash
# cx.sh — operations helper for the Reversi app (works locally and on the server).
# Usage: ./cx.sh <command> [args]   (./cx.sh help for the list)
set -euo pipefail
cd "$(dirname "$0")"

PHP=${PHP:-php}
COMPOSER=${COMPOSER:-composer}
BACKUP_DIR=${BACKUP_DIR:-storage/backups}
BACKUP_KEEP=${BACKUP_KEEP:-10}

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else B= G= Y= R= D= N=; fi
info() { echo "${B}→${N} $*"; }
ok()   { echo "${G}✓${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
die()  { echo "${R}✗${N} $*" >&2; exit 1; }
art()  { $PHP artisan "$@"; }
confirm() { [ "${YES:-0}" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }

# Read a value from .env (strips quotes; last definition wins).
envval() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }

# Set or add KEY=VALUE in .env.
envset() {
  [ -f .env ] || die ".env not found"
  if grep -qE "^$1=" .env; then
    local tmp; tmp=$(mktemp); awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' .env > "$tmp" && cat "$tmp" > .env && rm -f "$tmp"
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

DB_DRIVER() { local d; d=$(envval DB_CONNECTION); echo "${d:-sqlite}"; }
sqlite_path() { local db; db=$(envval DB_DATABASE); echo "${db:-database/database.sqlite}"; }
mysql_args() {  # connection args for mysql/mysqldump; password goes via MYSQL_PWD
  local host port; host=$(envval DB_HOST); port=$(envval DB_PORT)
  echo "-h ${host:-127.0.0.1} -P ${port:-3306} -u $(envval DB_USERNAME)"
}
db_ping() { art tinker --execute='DB::connection()->getPdo(); echo "ok";' 2>/dev/null | grep -q ok; }

usage() {
  cat <<USAGE
${B}Usage:${N} ./cx.sh <command> [args]     ${D}(YES=1 skips confirmations)${N}

${B}Setup${N}
  setup            Install deps, create .env + key, create DB, migrate
  doctor           Full health check (PHP, extensions, .env, DB, migrations, OAuth)
  check            Pre-deploy gate: exits non-zero if the app can't safely deploy
  google           Google OAuth setup values (redirect URI etc.)
  env:prod         Set production-safe .env values (APP_ENV, APP_DEBUG, log level)
  env:set K V      Set a value in .env

${B}Develop${N}
  serve [port]     Run the dev server (default 8000)
  test [filter]    Run tests
  routes           List app routes
  tinker           Open Tinker

${B}Database${N}  ${D}(SQLite and MySQL)${N}
  migrate          Run migrations
  migrate:status   Show migration status
  fresh            Drop all tables and re-migrate (backs up first; blocked in production)
  backup [label]   Back up the database to ${BACKUP_DIR} (keeps last ${BACKUP_KEEP})
  backups          List backups
  restore [file]   Restore a backup (latest if omitted)
  users            List registered users

${B}Maintenance${N}
  clear            Clear all caches
  optimize         Build production caches
  perms            Fix storage/ and bootstrap/cache permissions
  down | up        Toggle maintenance mode
  logs [n]         Tail the Laravel log
  status           App info + git status
USAGE
}

cmd=${1:-help}; shift || true
case "$cmd" in
  setup)
    info "Installing PHP dependencies"
    if [ "$(envval APP_ENV)" = production ]; then $COMPOSER install --no-dev --optimize-autoloader --no-interaction; else $COMPOSER install --no-interaction; fi
    [ -f .env ] || { cp .env.example .env; ok "Created .env"; }
    [ -n "$(envval APP_KEY)" ] || art key:generate --force
    if [ "$(DB_DRIVER)" = sqlite ]; then db=$(sqlite_path); [ -f "$db" ] || { touch "$db"; ok "Created $db"; }; fi
    db_ping || die "Cannot connect to the $(DB_DRIVER) database — check DB_* in .env"
    art migrate --force
    "$0" perms
    ok "Setup complete"
    ;;

  doctor|check)
    fail=0 warns=0
    # check <label> <command> <hint> [hard]  — hard checks fail 'check'; soft ones only warn
    check() {
      if eval "$2" >/dev/null 2>&1; then ok "$1"
      elif [ "${4:-soft}" = hard ]; then echo "${R}✗${N} $1 — $3"; fail=1
      else warn "$1 — $3"; warns=1; fi
    }
    prod=0; [ "$(envval APP_ENV)" = production ] && prod=1
    check "PHP $($PHP -r 'echo PHP_VERSION;') (CLI)" "$PHP -r 'exit(version_compare(PHP_VERSION,\"8.3\",\">=\")?0:1);'" "PHP 8.3+ required (set PHP=/path/to/php85)" hard
    exts="mbstring openssl curl pdo_$( [ "$(DB_DRIVER)" = mysql ] && echo mysql || echo sqlite )"
    for ext in $exts; do check "ext-$ext" "$PHP -r 'exit(extension_loaded(\"$ext\")?0:1);'" "missing PHP extension" hard; done
    check ".env present" "[ -f .env ]" "copy .env.example to .env" hard
    check "APP_KEY set" "[ -n \"$(envval APP_KEY)\" ]" "run: php artisan key:generate" hard
    check "vendor/ installed" "[ -f vendor/autoload.php ]" "run: composer install" hard
    check "storage writable" "[ -w storage/logs ] && [ -w storage/framework ] && [ -w bootstrap/cache ]" "run: ./cx.sh perms" hard
    if [ "$(DB_DRIVER)" = sqlite ]; then check "SQLite file exists" "[ -f \"$(sqlite_path)\" ]" "run: touch $(sqlite_path)" hard; fi
    check "Database reachable ($(DB_DRIVER))" "db_ping" "check DB_HOST/DB_DATABASE/DB_USERNAME/DB_PASSWORD" hard
    if [ "$cmd" = doctor ]; then
      check "Migrations up to date" "! art migrate:status 2>&1 | grep -qiE 'pending|not found'" "run: ./cx.sh migrate"
    fi
    if [ $prod -eq 1 ]; then
      check "APP_DEBUG=false" "[ \"$(envval APP_DEBUG)\" = false ]" "debug pages leak secrets — run: ./cx.sh env:prod"
      check "APP_URL uses https" "[[ \"$(envval APP_URL)\" == https://* ]]" "set APP_URL=https://your-domain"
    else
      warn "APP_ENV=$(envval APP_ENV) (not production)"
    fi
    check "Google OAuth configured" "[ -n \"$(envval GOOGLE_CLIENT_ID)\" ] && [ -n \"$(envval GOOGLE_CLIENT_SECRET)\" ]" "Google sign-in disabled (see ./cx.sh google)"
    [ $fail -eq 0 ] || die "Checks failed"
    [ $warns -eq 0 ] && ok "All checks passed" || ok "Passed with warnings"
    ;;

  google)
    url=$(envval APP_URL); url=${url:-http://localhost:8000}
    cat <<G
${B}Google OAuth setup${N}  (https://console.cloud.google.com/apis/credentials)
  1. Create an OAuth client ID → type "Web application"
  2. Authorized JavaScript origin:  ${G}${url}${N}
  3. Authorized redirect URI:       ${G}${url}/auth/google/callback${N}
  4. ./cx.sh env:set GOOGLE_CLIENT_ID ...    and    ./cx.sh env:set GOOGLE_CLIENT_SECRET ...
  5. ./cx.sh optimize

  Current: client id ${D}$( [ -n "$(envval GOOGLE_CLIENT_ID)" ] && echo set || echo "not set" )${N}, secret ${D}$( [ -n "$(envval GOOGLE_CLIENT_SECRET)" ] && echo set || echo "not set" )${N}
G
    ;;

  env:prod)
    envset APP_ENV production; envset APP_DEBUG false; envset LOG_LEVEL warning
    [[ "$(envval APP_URL)" == https://* ]] || warn "APP_URL is $(envval APP_URL) — set it to your https URL: ./cx.sh env:set APP_URL https://…"
    art config:clear >/dev/null; ok "Production values set — run ./cx.sh optimize"
    ;;
  env:set)
    [ $# -eq 2 ] || die "Usage: ./cx.sh env:set KEY VALUE"
    envset "$1" "$2"; art config:clear >/dev/null; ok "$1 updated"
    ;;

  serve)   art serve --port="${1:-${PORT:-8000}}" ;;
  test)    if [ $# -gt 0 ]; then art test --filter="$1"; else art test; fi ;;
  routes)  art route:list --except-vendor ;;
  tinker)  art tinker ;;

  migrate)        art migrate --force "$@" ;;
  migrate:status) art migrate:status ;;
  fresh)
    [ "$(envval APP_ENV)" = production ] && die "Refusing to run fresh in production"
    confirm "Drop ALL tables in the $(DB_DRIVER) database and re-migrate?" || exit 0
    "$0" backup pre-fresh || true
    art migrate:fresh --force
    ;;

  backup)
    mkdir -p "$BACKUP_DIR"
    label=${1:+-$1}; stamp=$(date +%Y%m%d-%H%M%S)
    case "$(DB_DRIVER)" in
      sqlite)
        db=$(sqlite_path); [ -f "$db" ] || die "No database at $db"
        out="$BACKUP_DIR/db-$stamp$label.sqlite"
        if command -v sqlite3 >/dev/null; then sqlite3 "$db" ".backup '$out'"; else cp "$db" "$out"; fi
        gzip -f "$out"; out="$out.gz" ;;
      mysql|mariadb)
        command -v mysqldump >/dev/null || die "mysqldump not found"
        out="$BACKUP_DIR/db-$stamp$label.sql.gz"
        # shellcheck disable=SC2046
        MYSQL_PWD=$(envval DB_PASSWORD) mysqldump $(mysql_args) --single-transaction --quick --no-tablespaces \
          --routines --triggers "$(envval DB_DATABASE)" | gzip > "$out"
        [ "$(gunzip -c "$out" | head -c 1 | wc -c)" -gt 0 ] || { rm -f "$out"; die "mysqldump produced no output"; } ;;
      *) die "Backup not supported for DB_CONNECTION=$(DB_DRIVER)" ;;
    esac
    chmod 600 "$out"
    ok "Backup: $out ($(du -h "$out" | cut -f1))"
    ls -1t "$BACKUP_DIR"/db-* 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r f; do rm -f "$f"; done
    ;;
  backups) ls -lht "$BACKUP_DIR"/db-* 2>/dev/null || warn "No backups in $BACKUP_DIR" ;;
  restore)
    f=${1:-$(ls -1t "$BACKUP_DIR"/db-* 2>/dev/null | head -1)}
    [ -n "$f" ] && [ -f "$f" ] || die "No backup found"
    confirm "Restore $f into the $(DB_DRIVER) database (current data will be replaced)?" || exit 0
    "$0" backup pre-restore || warn "Could not back up current DB first"
    case "$(DB_DRIVER)" in
      sqlite) gunzip -c "$f" > "$(sqlite_path)" ;;
      # shellcheck disable=SC2046
      mysql|mariadb) gunzip -c "$f" | MYSQL_PWD=$(envval DB_PASSWORD) mysql $(mysql_args) "$(envval DB_DATABASE)" ;;
      *) die "Restore not supported for DB_CONNECTION=$(DB_DRIVER)" ;;
    esac
    art optimize:clear >/dev/null; ok "Restored $f"
    ;;
  users)
    art tinker --execute='App\Models\User::query()->latest()->limit(50)->get(["id","name","email","google_id","created_at"])->each(fn($u)=>printf("%4d  %-24s %-32s %-7s %s\n",$u->id,$u->name,$u->email,$u->google_id?"google":"email",$u->created_at));'
    ;;

  clear)    art optimize:clear ;;
  optimize) art optimize ;;
  perms)    mkdir -p storage/framework/{cache,sessions,views} storage/logs; chmod -R ug+rwX storage bootstrap/cache; ok "Permissions fixed" ;;
  down)     art down --refresh=15 "$@" ;;
  up)       art up ;;
  logs)     f=storage/logs/laravel.log; [ -f "$f" ] || die "No log yet"; tail -n "${1:-100}" -f "$f" ;;
  status)   art about --only=environment,drivers; git status -sb; git log --oneline -5 ;;

  help|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
