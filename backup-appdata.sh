#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# Weekly appdata + Jellyfin backup -> hdd8tb
#
# Backs up the small, irreplaceable container state (configs, SQLite/Postgres
# DBs, torrents, certs, Jellyfin covers/intro-skipper data) and deliberately
# skips the big regenerable stuff (arr MediaCover/, Backups/ zips, logs,
# Jellyfin actor images, transcodes, cache). Media libraries are never under
# appdata, but guard patterns are in the exclude list anyway.
#
# Each run produces one directory:
#   /home/brad/media/hdd8tb/backups/appdata/YYYY-MM-DD_HHMM/
#       appdata.tar.zst   jellyfin.tar.zst   tandoor-db.sql.gz
#       excludes.txt      manifest.txt       run.log
# and only the KEEP newest complete runs are kept.
#
# Why it runs tar inside a container: several appdata dirs are root-owned
# (tandoor postgres, caddy certs, ...) and brad can't read them; cron has no
# sudo. `docker run alpine` gives us root for the read, then chowns the result
# back to brad.
#
# Containers to stop are chosen DYNAMICALLY: any running container that bind
# mounts something under SRC_APPDATA or SRC_JELLYFIN gets stopped for the copy
# (minus KEEP_RUNNING). New services are therefore covered automatically.
#
# Usage:
#   backup-appdata.sh            normal run (stops containers, ~5-10 min)
#   backup-appdata.sh --no-stop  live copy, no downtime (smoke test / ad hoc)
#   backup-appdata.sh --dry-run  show what would be stopped/excluded, do nothing
#
# Cron (brad's crontab, Sunday 03:30 local):
#   30 3 * * 0 /home/brad/docker/compose/backup-appdata.sh >> /home/brad/media/hdd8tb/backups/appdata/cron.log 2>&1
#
# RESTORE (run as root via a container so ownership comes back correctly):
#   Whole appdata tree (stop the affected containers first):
#     docker run --rm -v /home/brad/media/hdd8tb/backups/appdata/<RUN>:/bk:ro \
#         -v /home/brad/docker/appdata:/dst alpine:3 sh -c \
#         'apk add -q tar zstd && tar -C /dst --strip-components=1 --numeric-owner -I zstd -xf /bk/appdata.tar.zst'
#   One app only, e.g. vaultwarden: append  appdata/vaultwarden  to the tar command.
#   Jellyfin: same, with jellyfin.tar.zst and -v /home/brad/jellyfin:/dst.
#   Tandoor DB (if the raw tandoor/data dir is not enough):
#     gunzip -c tandoor-db.sql.gz | docker exec -i tandoor_db sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"'
#   Browse an archive:  zstd -dc appdata.tar.zst | tar -t | less
#############################################################################

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SRC_APPDATA="/home/brad/docker/appdata"
SRC_JELLYFIN="/home/brad/jellyfin"
BACKUP_MOUNT="/home/brad/media/hdd8tb"
BACKUP_ROOT="$BACKUP_MOUNT/backups/appdata"
KEEP=4
KEEP_RUNNING=(caddy)      # copied live so the proxy stays up for services we don't back up
STOP_TIMEOUT=60
OWNER="1000:1000"
TAR_IMAGE="alpine:3"
PG_CONTAINER="tandoor_db"

# Paths are relative to /src inside the tar container. GNU tar globs, anchored,
# '*' also matches '/'. Lines starting with # are stripped before use.
EXCLUDES=$(cat <<'EOF'
# --- arr apps (sonarr*, radarr*, readarr*, bookshelf*, prowlarr, ...) ---
appdata/*/MediaCover
appdata/*/Backups
appdata/*/logs
appdata/*/logs.db*
appdata/*/cache.db*
appdata/*/*.log
appdata/*/*.pid
# --- audiobookshelf: keep config + items/authors metadata, drop regenerable bits ---
# (audiobookshelf* also covers the older nested appdata/audiobookshelf/audiobookshelf/ tree)
appdata/audiobookshelf*/metadata/backups
appdata/audiobookshelf*/metadata/cache
appdata/audiobookshelf*/metadata/tmp
appdata/audiobookshelf*/metadata/logs
appdata/audiobookshelf.pre-migrate-*
# --- misc regenerable ---
appdata/tandoor/staticfiles
appdata/recyclarr/repositories
appdata/recyclarr/resources
# --- guard: book libraries must never live in appdata; if they ever do, skip them ---
appdata/calibre*/Calibre Library
appdata/calibre*/library
appdata/calibre*/books
# --- jellyfin: keep config, DBs, plugins, covers (metadata/library), custom
# --- library images (root/), collections, intro-skipper, subtitles ---
jellyfin/cache
jellyfin/log
jellyfin/data/transcodes
jellyfin/data/temp
jellyfin/data/metadata/People
jellyfin/data/data/library.db.bak*
jellyfin/data/data/library.db.old*
# --- stray temp files from deleted-while-open handles (any depth) ---
*/.fuse_hidden*
EOF
)

DRY_RUN=0
NO_STOP=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --no-stop) NO_STOP=1 ;;
        -h|--help) sed -n '3,45p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
[[ -t 1 ]] || { GREEN=''; YELLOW=''; RED=''; NC=''; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo -e "${GREEN}[$(ts) INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(ts) WARN]${NC} $*"; }
err()  { echo -e "${RED}[$(ts) ERROR]${NC} $*" >&2; }

START_EPOCH=$(date +%s)
STAMP=$(date '+%Y-%m-%d_%H%M')
RUN_DIR="$BACKUP_ROOT/$STAMP"
PARTIAL_DIR="$RUN_DIR.partial"

STOPPED=()
NEED_RESTART=0

restart_containers() {
    if [[ $NEED_RESTART -eq 1 && ${#STOPPED[@]} -gt 0 ]]; then
        log "Starting containers: ${STOPPED[*]}"
        docker start "${STOPPED[@]}" >/dev/null || warn "Some containers failed to start; check 'docker ps -a'"
        NEED_RESTART=0
    fi
}
on_exit() {
    local rc=$?
    restart_containers
    if [[ $rc -ne 0 ]]; then
        err "Backup FAILED (exit $rc). Partial output left in $PARTIAL_DIR for inspection; it will be removed on the next run."
    fi
}
trap on_exit EXIT

#############################################################################
# 1. Preflight
#############################################################################
if ! mountpoint -q "$BACKUP_MOUNT"; then
    err "$BACKUP_MOUNT is not mounted. Refusing to write onto the root filesystem."
    exit 1
fi
for d in "$SRC_APPDATA" "$SRC_JELLYFIN"; do
    [[ -d "$d" ]] || { err "Source dir missing: $d"; exit 1; }
done
command -v docker >/dev/null || { err "docker not found in PATH"; exit 1; }

#############################################################################
# 2. Work out which containers to stop (bind mounts under the source trees)
#############################################################################
in_keep_running() {
    local c; for c in "${KEEP_RUNNING[@]}"; do [[ "$1" == "$c" ]] && return 0; done; return 1
}

TO_STOP=()
while IFS='|' read -r name mounts; do
    name="${name#/}"
    [[ -n "$name" ]] || continue
    hit=0
    IFS=';' read -ra srcs <<<"$mounts"
    for s in "${srcs[@]}"; do
        [[ -n "$s" ]] || continue
        for prefix in "$SRC_APPDATA" "$SRC_JELLYFIN"; do
            if [[ "$s" == "$prefix" || "$s" == "$prefix/"* ]]; then hit=1; fi
        done
    done
    if [[ $hit -eq 1 ]]; then
        if in_keep_running "$name"; then
            log "  keep running (copied live): $name"
        else
            TO_STOP+=("$name")
        fi
    fi
done < <(docker ps -q | xargs -r docker inspect -f '{{.Name}}|{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}};{{end}}{{end}}')

mapfile -t TO_STOP < <(printf '%s\n' "${TO_STOP[@]}" | sort)

#############################################################################
# 3. Dry run: report and leave
#############################################################################
if [[ $DRY_RUN -eq 1 ]]; then
    echo
    log "Would write to: $RUN_DIR"
    log "Would stop ${#TO_STOP[@]} containers:"
    printf '    %s\n' "${TO_STOP[@]}"
    log "Exclude patterns:"
    printf '%s\n' "$EXCLUDES" | grep -v '^#' | sed 's/^/    /'
    log "Retention: keep $KEEP newest runs in $BACKUP_ROOT"
    log "Existing runs:"
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | sed 's/^/    /' || true
    exit 0
fi

#############################################################################
# 4. Create run dir, start logging into it
#############################################################################
mkdir -p "$BACKUP_ROOT"
for old in "$BACKUP_ROOT"/*.partial; do
    [[ -d "$old" ]] || continue
    warn "Removing leftover partial run: $old"
    rm -rf "$old"
done
mkdir -p "$PARTIAL_DIR"
exec > >(tee -a "$PARTIAL_DIR/run.log") 2>&1

log "=== appdata backup starting -> $RUN_DIR"
[[ $NO_STOP -eq 1 ]] && warn "--no-stop: containers stay running; SQLite copies may be slightly inconsistent"

printf '%s\n' "$EXCLUDES" | grep -v '^#' | sed '/^$/d' > "$PARTIAL_DIR/excludes.txt"

#############################################################################
# 5. Postgres dump while the DB is still up
#############################################################################
if docker ps -q -f "name=^${PG_CONTAINER}$" | grep -q .; then
    log "pg_dump from $PG_CONTAINER"
    if docker exec "$PG_CONTAINER" sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip -6 > "$PARTIAL_DIR/tandoor-db.sql.gz"; then
        log "  tandoor-db.sql.gz: $(du -h "$PARTIAL_DIR/tandoor-db.sql.gz" | cut -f1)"
    else
        warn "  pg_dump failed; the raw tandoor/data directory is still in the tar"
        rm -f "$PARTIAL_DIR/tandoor-db.sql.gz"
    fi
else
    warn "$PG_CONTAINER not running; skipping pg_dump"
fi

#############################################################################
# 6. Stop containers
#############################################################################
if [[ $NO_STOP -eq 0 && ${#TO_STOP[@]} -gt 0 ]]; then
    log "Stopping ${#TO_STOP[@]} containers (timeout ${STOP_TIMEOUT}s): ${TO_STOP[*]}"
    STOPPED=("${TO_STOP[@]}")
    NEED_RESTART=1
    docker stop -t "$STOP_TIMEOUT" "${STOPPED[@]}" >/dev/null
    log "Stopped."
fi

#############################################################################
# 7. Tar as root inside a container
#############################################################################
log "Archiving (zstd -3, all cores)..."
TAR_WARN=""
[[ $NO_STOP -eq 1 ]] && TAR_WARN="--warning=no-file-changed --warning=no-file-removed"
set +e
docker run --rm \
    -v "$SRC_APPDATA:/src/appdata:ro" \
    -v "$SRC_JELLYFIN:/src/jellyfin:ro" \
    -v "$PARTIAL_DIR:/dest" \
    -e OWNER="$OWNER" -e TAR_WARN="$TAR_WARN" \
    "$TAR_IMAGE" sh -euc '
        apk add --no-cache -q tar zstd >/dev/null
        rc=0
        for set in appdata jellyfin; do
            tar -C /src --anchored --wildcards --wildcards-match-slash \
                -X /dest/excludes.txt --numeric-owner $TAR_WARN \
                -I "zstd -T0 -3" -cf "/dest/$set.tar.zst" "$set" || r=$?
            [ "${r:-0}" -gt "$rc" ] && rc=$r; r=0
        done
        chown -R "$OWNER" /dest
        exit $rc'
rc=$?
set -e
if [[ $rc -eq 1 ]]; then
    warn "tar reported changed files while reading (exit 1); archive is still usable"
elif [[ $rc -ne 0 ]]; then
    err "tar failed with exit $rc"
    exit $rc
fi

#############################################################################
# 8. Restart containers
#############################################################################
restart_containers

#############################################################################
# 9. Manifest, finalize, prune
#############################################################################
{
    echo "run:            $STAMP"
    echo "host:           $(hostname)"
    echo "mode:           $([[ $NO_STOP -eq 1 ]] && echo live-copy || echo stopped-containers)"
    echo "duration:       $(( $(date +%s) - START_EPOCH ))s"
    echo "sources:        $SRC_APPDATA  $SRC_JELLYFIN"
    echo
    echo "containers stopped (${#STOPPED[@]}):"
    printf '  %s\n' "${STOPPED[@]:-<none>}"
    echo
    echo "archives:"
    for f in "$PARTIAL_DIR"/*.tar.zst "$PARTIAL_DIR"/*.sql.gz; do
        [[ -f "$f" ]] || continue
        printf '  %-20s %8s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    done
    echo
    echo "entries:"
    for f in "$PARTIAL_DIR"/*.tar.zst; do
        printf '  %-20s %8s files\n' "$(basename "$f")" "$(zstd -dc "$f" | tar -t | wc -l)"
    done
} > "$PARTIAL_DIR/manifest.txt"

mv "$PARTIAL_DIR" "$RUN_DIR"
log "Run complete: $RUN_DIR ($(du -sh "$RUN_DIR" | cut -f1))"
cat "$RUN_DIR/manifest.txt" | sed 's/^/    /'

# Keep only the KEEP newest complete runs (dirs named YYYY-MM-DD_HHMM)
mapfile -t RUNS < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$' | sort)
if (( ${#RUNS[@]} > KEEP )); then
    for old in "${RUNS[@]:0:${#RUNS[@]}-KEEP}"; do
        log "Pruning old run: $old"
        rm -rf "$old"
    done
fi
log "Retained runs: $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$' | wc -l) / $KEEP"
log "=== done in $(( $(date +%s) - START_EPOCH ))s"
