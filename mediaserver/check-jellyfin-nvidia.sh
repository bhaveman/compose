#!/bin/bash
#
# Author: Alex Fornuto <alex@fornuto.com>
#
##############################################################
# This script checks if the Jellyfin docker container        #
# has access to the GPU, and restarts it if not. it          #
# assumes an nvidia GPU and the native docker compose plugin #
##############################################################

# The test command
cmd="docker compose exec -it jellyfin nvidia-smi"

# The command to restart the container
fix="docker compose restart jellyfin"

# Run the script where it's located, which should be the directory with
# your docker-compose.yaml file.
cd "${0%/*}"

# Load NTFY credentials from .env. If you're not using NTFY, comment out.
#set -a
#source .env
#set +a

# Evaluate
if $cmd
then
  printf "$(date): GPU connection confirmed.\n"
  exit 0
else
  printf "$(date): GPU Connection failed, restarting container...\n"
  if $fix
  then
    printf "$(date): Jellyfin container restarted.\n"
    # Report to NTFY. Comment out if not using NTFY.
    #ntfy publish -u $NTFYUSERPASS --title "Jellyfin" --tags warning ntfy.example.com/status "Jellyfin lost access to the GPU, was restarted."
    exit 0
  else
    printf "$(date): Restart failed, manual action required. \n"
    # Report to NTFY Comment out if not using NTFY.
    #ntfy publish -u $NTFYUSERPASS --title "Jellyfin" --tags skull ntfy.example.com/status "Jellyfin lost access to the GPU, restart failed. Manual action required"
    exit 1
  fi
fi
