#!/usr/bin/env bash
# Capture / replay Tandoor food-merge history so it can be turned into automations.
#
# WHY
#   Food.merge_into() repoints ingredients and then hard-deletes the source food.
#   No automation and no audit row is written, so the old name is gone forever and
#   there is nothing left to build a FOOD_ALIAS or regex rule from.
#
#   But the merge is observable: it does
#       Ingredient.objects.filter(food=self).update(food=target)
#   so snapshotting (ingredient_id -> food_id, food_name) BEFORE a merge session lets
#   us diff afterwards. Any ingredient that moved from food A to food B reconstructs
#   the merge A -> B exactly.
#
# Usage:
#   ./tandoor-merge-tracker.sh snapshot     # run BEFORE merging in the GUI
#   ./tandoor-merge-tracker.sh diff         # run AFTER - prints recovered merge map
#
set -euo pipefail

DB_CONTAINER="${TANDOOR_DB_CONTAINER:-tandoor_db}"
DB_USER="${TANDOOR_DB_USER:-djangouser}"
DB_NAME="${TANDOOR_DB_NAME:-djangodb}"
STATE_DIR="${TANDOOR_STATE_DIR:-/home/brad/docker/backups/tandoor/merge-tracking}"
SNAPSHOT="$STATE_DIR/ingredient-food-snapshot.csv"

psql_csv() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -qtAF',' -c "$1"; }

case "${1:-}" in
  snapshot)
    mkdir -p "$STATE_DIR"
    [[ -f "$SNAPSHOT" ]] && cp "$SNAPSHOT" "$SNAPSHOT.$(date +%Y%m%d-%H%M%S).bak"
    psql_csv "SELECT i.id, i.food_id, f.name
              FROM cookbook_ingredient i JOIN cookbook_food f ON f.id = i.food_id
              WHERE i.food_id IS NOT NULL ORDER BY i.id;" > "$SNAPSHOT"
    echo "Snapshot: $(wc -l < "$SNAPSHOT") ingredient->food rows -> $SNAPSHOT"
    echo "Now go merge / add automations in the GUI, then run: $0 diff"
    ;;

  diff)
    [[ -f "$SNAPSHOT" ]] || { echo "ERROR: no snapshot at $SNAPSHOT - run '$0 snapshot' first" >&2; exit 1; }
    TMP=$(mktemp)
    psql_csv "SELECT i.id, i.food_id, f.name
              FROM cookbook_ingredient i JOIN cookbook_food f ON f.id = i.food_id
              WHERE i.food_id IS NOT NULL ORDER BY i.id;" > "$TMP"

    echo "=== Recovered merges (old name -> new name, N ingredients moved) ==="
    awk -F',' '
      NR==FNR { of[$1]=$2; on[$1]=$3; next }
      ($1 in of) && of[$1] != $2 {
        key = on[$1] "\t->\t" $3
        cnt[key]++
      }
      END {
        n=0
        for (k in cnt) { printf "%5d  %s\n", cnt[k], k; n++ }
        if (n==0) print "(none detected)"
      }
    ' "$SNAPSHOT" "$TMP" | sort -rn

    echo
    echo "=== Foods that disappeared entirely ==="
    awk -F',' '
      NR==FNR { seen[$3]=1; next }
      { now[$3]=1 }
      END { n=0; for (f in seen) if (!(f in now)) { print "  " f; n++ }
            if (n==0) print "  (none)" }
    ' "$SNAPSHOT" "$TMP" | sort

    rm -f "$TMP"
    ;;

  *)
    echo "Usage: $0 {snapshot|diff}" >&2; exit 1 ;;
esac
