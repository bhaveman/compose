#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# Appdata Migration Script
#
# Migrates appdata from /home/brad/docker/appdata → /home/brad/media/ssd2tb/appdata
#
# EXCEPTIONS (stay on fast storage, NOT migrated):
#   - caddy   → stays at /home/brad/docker/appdata/caddy
#   - crafty  → stays at /home/brad/docker/appdata/crafty
#   - jellyfin → already at /home/brad/jellyfin (not under appdata)
#
# WHAT THIS SCRIPT DOES:
#   1. Stops all affected containers (caddy, crafty, jellyfin keep running)
#   2. rsyncs each appdata folder to the new SSD location
#   3. Replaces each migrated folder with a symlink (old → new) as safety net
#   4. Moves misplaced qdirstat data from /docker/appdata/qdirstat
#   5. Brings all services back up
#
# PRE-REQUISITES (already done):
#   - .env updated: APPDATA → ssd2tb, APPDATAPERFORMANCE → old location
#   - caddy compose updated to use $APPDATAPERFORMANCE
#   - paperless-ngx compose updated to use $APPDATA + .env symlink created
#   - gameservers teamspeak path updated
#   - management qdirstat path updated
#############################################################################

OLD_APPDATA="/home/brad/docker/appdata"
NEW_APPDATA="/home/brad/media/ssd2tb/appdata"
COMPOSE_DIR="/home/brad/docker/compose"

# Folders to SKIP (stay at old location for performance)
SKIP_FOLDERS=("caddy" "crafty")

# Containers in mediaserver stack to stop (all EXCEPT jellyfin)
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
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

confirm() {
    echo ""
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW} Appdata Migration: $OLD_APPDATA → $NEW_APPDATA${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo "This script will:"
    echo "  1. Stop management, tools, cloveanddagger, paperless-ngx stacks"
    echo "  2. Stop mediaserver containers (except jellyfin)"
    echo "  3. Stop teamspeak in gameservers (crafty stays running)"
    echo "  4. rsync all appdata folders to $NEW_APPDATA (except caddy, crafty)"
    echo "  5. Move qdirstat data from /docker/appdata/qdirstat"
    echo "  6. Replace migrated folders with symlinks"
    echo "  7. Bring everything back up"
    echo ""
    echo "Caddy, crafty, and jellyfin will NOT be stopped."
    echo ""
    read -rp "Proceed? (y/N) " response
    [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

should_skip() {
    local folder="$1"
    for skip in "${SKIP_FOLDERS[@]}"; do
        [[ "$folder" == "$skip" ]] && return 0
    done
    return 1
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

migrate_data() {
    log "Creating target directory: $NEW_APPDATA"
    mkdir -p "$NEW_APPDATA"

    log "Migrating appdata folders..."
    echo ""

    local migrated=0
    local skipped=0
    local failed=0

    for dir in "$OLD_APPDATA"/*/; do
        [[ -L "${dir%/}" ]] && continue
        [[ -d "$dir" ]] || continue

        local folder_name
        folder_name=$(basename "$dir")

        if should_skip "$folder_name"; then
            log "  SKIP: $folder_name"
            skipped=$((skipped + 1))
            continue
        fi

        log "  Syncing: $folder_name ..."
        set +e
        sudo rsync -a --info=progress2 "$dir" "$NEW_APPDATA/$folder_name/"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            migrated=$((migrated + 1))
        else
            err "  FAILED ($rc): $folder_name"
            failed=$((failed + 1))
        fi
    done

    echo ""
    log "Migration summary: $migrated migrated, $skipped skipped, $failed failed"

    if [[ $failed -gt 0 ]]; then
        err "Some folders failed to sync. Fix issues and re-run, or proceed carefully."
        read -rp "Continue with symlink creation anyway? (y/N) " response
        [[ "$response" =~ ^[Yy]$ ]] || { err "Aborted before symlinks."; exit 1; }
    fi
}

migrate_qdirstat() {
    local qdirstat_src="/docker/appdata/qdirstat"
    if [[ -d "$qdirstat_src" && ! -L "$qdirstat_src" ]]; then
        log "Moving misplaced qdirstat data from $qdirstat_src ..."
        rsync -a --info=progress2 "$qdirstat_src/" "$NEW_APPDATA/qdirstat/"
        # Replace with symlink
        sudo rm -rf "$qdirstat_src"
        sudo ln -s "$NEW_APPDATA/qdirstat" "$qdirstat_src"
        log "  Created symlink: $qdirstat_src → $NEW_APPDATA/qdirstat"
    else
        warn "  /docker/appdata/qdirstat not found or already a symlink, skipping"
    fi
}

create_symlinks() {
    log "Creating symlinks from old locations → new locations..."
    echo ""

    for dir in "$NEW_APPDATA"/*/; do
        [[ -d "$dir" ]] || continue
        local folder_name
        folder_name=$(basename "$dir")

        local old_path="$OLD_APPDATA/$folder_name"

        if should_skip "$folder_name"; then
            continue
        fi

        if [[ -L "$old_path" ]]; then
            log "  Already a symlink: $folder_name"
            continue
        fi

        if [[ -d "$old_path" ]]; then
            # Verify the new copy exists and has content before removing old
            local new_count old_count
            new_count=$(find "$NEW_APPDATA/$folder_name" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
            old_count=$(find "$old_path" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)

            if [[ $old_count -gt 0 && $new_count -eq 0 ]]; then
                err "  SAFETY: $folder_name — old has $old_count items, new has 0. SKIPPING symlink."
                continue
            fi

            sudo rm -rf "$old_path"
            ln -s "$NEW_APPDATA/$folder_name" "$old_path"
            log "  Symlink: $old_path → $NEW_APPDATA/$folder_name"
        fi
    done
    echo ""
}

start_services() {
    log "Starting all services back up..."

    log "Starting management stack..."
    cd "$COMPOSE_DIR/management" && docker compose up -d 2>&1 || warn "management stack had warnings"

    log "Starting tools stack..."
    cd "$COMPOSE_DIR/tools" && docker compose up -d 2>&1 || warn "tools stack had warnings"

    log "Starting cloveanddagger stack..."
    cd "$COMPOSE_DIR/cloveanddagger" && docker compose up -d 2>&1 || warn "cloveanddagger stack had warnings"

    log "Starting paperless-ngx stack..."
    cd "$COMPOSE_DIR/paperless-ngx" && docker compose up -d 2>&1 || warn "paperless-ngx stack had warnings"

    log "Starting mediaserver stack (jellyfin already running, compose will leave it alone)..."
    cd "$COMPOSE_DIR/mediaserver" && docker compose up -d 2>&1 || warn "mediaserver stack had warnings"

    log "Starting gameservers stack (crafty already running, compose will leave it alone)..."
    cd "$COMPOSE_DIR/gameservers" && docker compose up -d 2>&1 || warn "gameservers stack had warnings"
}

verify() {
    echo ""
    log "========== VERIFICATION =========="
    echo ""

    log "Checking symlinks in $OLD_APPDATA:"
    for dir in "$NEW_APPDATA"/*/; do
        local folder_name
        folder_name=$(basename "$dir")
        local old_path="$OLD_APPDATA/$folder_name"
        if [[ -L "$old_path" ]]; then
            local target
            target=$(readlink "$old_path")
            echo "  ✓ $folder_name → $target"
        elif should_skip "$folder_name"; then
            echo "  ● $folder_name (kept in place — performance)"
        else
            echo "  ✗ $folder_name — NOT a symlink!"
        fi
    done

    echo ""
    log "Performance folders still in place:"
    for skip in "${SKIP_FOLDERS[@]}"; do
        if [[ -d "$OLD_APPDATA/$skip" && ! -L "$OLD_APPDATA/$skip" ]]; then
            echo "  ✓ $skip — real directory at $OLD_APPDATA/$skip"
        else
            echo "  ✗ $skip — MISSING or is a symlink!"
        fi
    done

    echo ""
    log "Disk usage:"
    du -sh "$NEW_APPDATA" 2>/dev/null || true
    du -sh "$OLD_APPDATA" 2>/dev/null || true

    echo ""
    log "Running containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}" | sort

    echo ""
    log "Done! Check services in your browser to verify everything works."
}

#############################################################################
# MAIN
#############################################################################

confirm
stop_services
migrate_data
migrate_qdirstat
create_symlinks
start_services
verify
