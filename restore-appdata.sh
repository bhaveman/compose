#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# Appdata Restore Script
#
# Reverses the migration: moves appdata back from ~/media/ssd128/appdata
# to ~/docker/appdata and removes symlinks.
#
# WHAT THIS SCRIPT DOES:
#   1. Stops all affected containers
#   2. For each symlink in ~/docker/appdata pointing to ~/media/ssd128/appdata:
#      - Removes the symlink
#      - Moves the real directory to ~/docker/appdata/<name>
#   3. Updates APPDATA in ~/docker/compose/.env to /home/brad/docker/appdata
#   4. Brings all services back up
#
# NOTES:
#   - caddy, crafty, and jellyfin are not affected (already on ~/docker/appdata)
#   - APPDATAPERFORMANCE is left unchanged (already points to ~/docker/appdata)
#   - After this script, APPDATA == APPDATAPERFORMANCE (both on NVMe)
#############################################################################

SSD_APPDATA="/home/brad/media/ssd128/appdata"
NVME_APPDATA="/home/brad/docker/appdata"
COMPOSE_DIR="/home/brad/docker/compose"
ENV_FILE="$COMPOSE_DIR/.env"

MEDIASERVER_CONTAINERS=(
    nzbget
    qbittorrent
    radarr
    radarr4k
    sonarr
    sonarr-anime
    prowlarr
    unpackerr
    bookshelf
    bookshelf-audio
    lazylibrarian
    calibre
    calibre-web
    calibre-ttrpg
    audiobookshelf
    wizarr
    jellyseerr
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

confirm() {
    echo ""
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW} Appdata Restore: $SSD_APPDATA → $NVME_APPDATA${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo "This script will:"
    echo "  1. Stop management, tools, cloveanddagger, paperless-ngx stacks"
    echo "  2. Stop mediaserver containers (except jellyfin)"
    echo "  3. Stop teamspeak in gameservers (crafty stays running)"
    echo "  4. For each symlink in $NVME_APPDATA:"
    echo "       - Remove symlink"
    echo "       - Move real data from $SSD_APPDATA/<name> to $NVME_APPDATA/<name>"
    echo "  5. Update APPDATA in $ENV_FILE to $NVME_APPDATA"
    echo "  6. Bring all services back up"
    echo ""
    echo "Caddy, crafty, and jellyfin will NOT be stopped."
    echo ""
    read -rp "Proceed? (y/N) " response
    [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

stop_services() {
    log "Stopping management stack..."
    cd "$COMPOSE_DIR/management" && docker compose down --remove-orphans 2>&1 || warn "management stack stop had warnings"

    log "Stopping tools stack..."
    cd "$COMPOSE_DIR/tools" && docker compose down --remove-orphans 2>&1 || warn "tools stack stop had warnings"

    log "Stopping cloveanddagger stack..."
    cd "$COMPOSE_DIR/cloveanddagger" && docker compose down --remove-orphans 2>&1 || warn "cloveanddagger stack stop had warnings"

    log "Stopping paperless-ngx stack..."
    cd "$COMPOSE_DIR/paperless-ngx" && docker compose down --remove-orphans 2>&1 || warn "paperless-ngx stack stop had warnings"

    log "Stopping mediaserver containers (except jellyfin)..."
    for cname in "${MEDIASERVER_CONTAINERS[@]}"; do
        if docker ps -q -f "name=^${cname}$" | grep -q .; then
            docker stop "$cname" 2>&1 && log "  Stopped $cname" || warn "  Failed to stop $cname"
        else
            warn "  $cname not running, skipping"
        fi
    done

    log "Stopping teamspeak..."
    docker stop teamspeak-server 2>&1 && log "  Stopped teamspeak-server" || warn "  teamspeak-server not running"
}

restore_one() {
    local folder_name="$1"
    local src="$SSD_APPDATA/$folder_name"
    local dst="$NVME_APPDATA/$folder_name"

    if [[ ! -d "$src" ]]; then
        warn "  Source not found, skipping: $src"
        return 2
    fi

    log "  Restoring: $folder_name ..."
    mkdir -p "$dst"

    set +e
    sudo rsync -a --remove-source-files "$src/" "$dst/"
    local rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
        # Remove now-empty source directory tree
        sudo rm -rf "$src"
        log "    OK: $folder_name"
        return 0
    else
        err "    FAILED ($rc): $folder_name — source data left intact at $src"
        return 1
    fi
}

restore_data() {
    log "Restoring appdata from $SSD_APPDATA → $NVME_APPDATA ..."
    echo ""

    local moved=0
    local skipped=0
    local failed=0

    # Collect all names to process:
    #   1. Current symlinks pointing into SSD_APPDATA
    #   2. Real directories in NVME_APPDATA that still have a counterpart in SSD_APPDATA
    #      (left over from a previous partial/failed run)
    declare -A to_restore

    for link in "$NVME_APPDATA"/*/; do
        local link_path="${link%/}"
        local folder_name
        folder_name=$(basename "$link_path")

        if [[ -L "$link_path" ]]; then
            # Normal case: symlink to migrate
            to_restore["$folder_name"]=1
        elif [[ -d "$link_path" && -d "$SSD_APPDATA/$folder_name" ]]; then
            # Partial previous run: real dir exists on both sides, need to finish
            warn "  Detected partial previous run for: $folder_name — will resume rsync"
            to_restore["$folder_name"]=1
        fi
    done

    # Also catch any SSD entries that have no NVME counterpart yet (shouldn't happen, but safe)
    for dir in "$SSD_APPDATA"/*/; do
        local folder_name
        folder_name=$(basename "${dir%/}")
        [[ -n "${to_restore[$folder_name]+_}" ]] && continue
        if [[ ! -e "$NVME_APPDATA/$folder_name" ]]; then
            warn "  Found unmigrated entry with no NVME counterpart: $folder_name — adding to restore list"
            to_restore["$folder_name"]=1
        fi
    done

    for folder_name in "${!to_restore[@]}"; do
        local link_path="$NVME_APPDATA/$folder_name"
        # Remove symlink if still present
        [[ -L "$link_path" ]] && rm "$link_path"

        restore_one "$folder_name"
        local rc=$?
        case $rc in
            0) moved=$((moved + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done

    echo ""
    log "Restore summary: $moved moved, $skipped skipped, $failed failed"

    if [[ $failed -gt 0 ]]; then
        err "Some folders failed. Check above and resolve manually."
        read -rp "Continue with .env update and service restart anyway? (y/N) " response
        [[ "$response" =~ ^[Yy]$ ]] || { err "Aborted."; exit 1; }
    fi
}

update_env() {
    log "Updating APPDATA in $ENV_FILE ..."
    sed -i "s|^APPDATA=.*|APPDATA=\"$NVME_APPDATA\"|" "$ENV_FILE"
    log "  APPDATA is now: $NVME_APPDATA"
    log "  (APPDATAPERFORMANCE unchanged — already points to same location)"
}

start_services() {
    log "Starting paperless-ngx stack..."
    cd "$COMPOSE_DIR/paperless-ngx" && docker compose up -d 2>&1 || warn "paperless-ngx start had warnings"

    log "Starting cloveanddagger stack..."
    cd "$COMPOSE_DIR/cloveanddagger" && docker compose up -d 2>&1 || warn "cloveanddagger start had warnings"

    log "Starting tools stack..."
    cd "$COMPOSE_DIR/tools" && docker compose up -d 2>&1 || warn "tools start had warnings"

    log "Starting management stack..."
    cd "$COMPOSE_DIR/management" && docker compose up -d 2>&1 || warn "management start had warnings"

    log "Starting mediaserver stack..."
    cd "$COMPOSE_DIR/mediaserver" && docker compose up -d 2>&1 || warn "mediaserver start had warnings"

    log "Starting teamspeak (gameservers stack)..."
    cd "$COMPOSE_DIR/gameservers" && docker compose up -d teamspeak-server 2>&1 || warn "teamspeak start had warnings"
}

confirm
stop_services
restore_data
update_env
start_services

echo ""
log "Done! All appdata is now back on the NVMe at $NVME_APPDATA"
log "APPDATA and APPDATAPERFORMANCE both resolve to $NVME_APPDATA"
