#!/usr/bin/env bash
# Remove orphaned Tandoor steps/ingredients/foods left behind by deleted recipes.
#
# WHY THIS IS NEEDED
#   Recipe.steps and Step.ingredients are ManyToManyFields. Deleting a recipe only
#   drops the join-table rows - the Step and Ingredient objects survive forever, and
#   their Foods keep showing up in the food list. This leaks on every recipe delete
#   or re-import, so re-run this periodically.
#
# WHY THE ORM AND NOT SQL
#   Food is a django-treebeard MP_Node. Raw DELETEs corrupt path/depth/numchild.
#   This goes through the ORM and calls fix_tree() afterwards.
#
# CORRECTNESS NOTE
#   "Unused" must mean unreachable via Recipe -> Step -> Ingredient -> Food.
#   Testing "does the food have an ingredient row" gives false positives, because
#   orphaned ingredient rows from deleted recipes still point at the food.
#
# Usage:
#   ./tandoor-cleanup-orphans.sh            # dry run, reports only
#   ./tandoor-cleanup-orphans.sh --apply    # back up, then delete
#
set -euo pipefail

WEB_CONTAINER="${TANDOOR_WEB_CONTAINER:-tandoor}"
DB_CONTAINER="${TANDOOR_DB_CONTAINER:-tandoor_db}"
DB_USER="${TANDOOR_DB_USER:-djangouser}"
DB_NAME="${TANDOOR_DB_NAME:-djangodb}"
BACKUP_DIR="${TANDOOR_BACKUP_DIR:-/home/brad/docker/backups/tandoor}"
PYBIN="/opt/recipes/venv/bin/python"   # NOT bare `python` - Django lives in the venv

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

for c in "$WEB_CONTAINER" "$DB_CONTAINER"; do
  docker ps --format '{{.Names}}' | grep -qx "$c" || { echo "ERROR: container '$c' not running" >&2; exit 1; }
done

if [[ $APPLY -eq 1 ]]; then
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/tandoor-$(date +%Y%m%d-%H%M%S).dump"
  echo "==> Backing up to $BACKUP"
  docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$BACKUP"
  [[ -s "$BACKUP" ]] || { echo "ERROR: backup is empty, refusing to delete" >&2; exit 1; }
  echo "    $(du -h "$BACKUP" | cut -f1)"
  echo "    restore: docker exec -i $DB_CONTAINER pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists < $BACKUP"
else
  echo "==> DRY RUN (pass --apply to delete)"
fi

APPLY=$APPLY docker exec -i -e APPLY="$APPLY" -w /opt/recipes "$WEB_CONTAINER" "$PYBIN" manage.py shell <<'PY'
import os
from django_scopes import scopes_disabled
from cookbook.models import Food, Ingredient, Step, Recipe

apply = os.environ.get('APPLY') == '1'

with scopes_disabled():
    # Reachability: only things hanging off a real Recipe are live.
    live_steps = {i for i in Recipe.objects.values_list('steps__id', flat=True) if i}
    live_ings = {i for i in Step.objects.filter(id__in=live_steps)
                 .values_list('ingredients__id', flat=True) if i}
    live_foods = {i for i in Ingredient.objects.filter(id__in=live_ings)
                  .values_list('food_id', flat=True) if i}

    dead_steps = Step.objects.exclude(id__in=live_steps)
    dead_ings = Ingredient.objects.exclude(id__in=live_ings)
    dead_foods = Food.objects.exclude(id__in=live_foods)

    print("recipes=%d" % Recipe.objects.count())
    print("steps       %5d total  %5d orphaned" % (Step.objects.count(), dead_steps.count()))
    print("ingredients %5d total  %5d orphaned" % (Ingredient.objects.count(), dead_ings.count()))
    print("foods       %5d total  %5d orphaned" % (Food.objects.count(), dead_foods.count()))

    if not apply:
        for f in dead_foods.order_by('name')[:25]:
            print("   would delete food: %s" % f.name)
        if dead_foods.count() > 25:
            print("   ... and %d more" % (dead_foods.count() - 25))
        raise SystemExit(0)

    # Guard: an empty reachability set means a broken join, not an empty database.
    if not live_steps or not live_foods:
        raise SystemExit("ABORT: reachability came back empty")

    print("del steps:      ", dead_steps.delete())
    print("del ingredients:", dead_ings.delete())
    print("del foods:      ", dead_foods.delete())

    Food.fix_tree(fix_paths=True)

    print("AFTER recipes=%d steps=%d ingredients=%d foods=%d" % (
        Recipe.objects.count(), Step.objects.count(),
        Ingredient.objects.count(), Food.objects.count()))

    # Every recipe must still resolve ingredients.
    broken = [r.name for r in Recipe.objects.all()
              if not Ingredient.objects.filter(step__recipe=r).exists()]
    print("recipes left with no ingredients: %d%s" % (
        len(broken), (" -> " + ", ".join(broken[:5])) if broken else ""))
PY

echo "==> Done"
