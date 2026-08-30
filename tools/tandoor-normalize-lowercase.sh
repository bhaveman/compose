#!/usr/bin/env bash
# Normalize Tandoor food / unit / keyword names to lowercase.
#
# WHY IT HAS TO TOUCH AUTOMATIONS TOO
#   IngredientParser.get_food() / get_unit() match CASE-SENSITIVELY and create on miss:
#       Food.objects.filter(space=..).filter(Q(name=n) | Q(plural_name=n)).first()
#       ... else Food.objects.create(space=.., name=n)
#   A FOOD_ALIAS whose param_2 is 'Salt' will therefore CREATE a new food 'Salt' on the
#   next import once the real food has been renamed to 'salt'. Alias targets and
#   plural_name must be lowercased in the same pass or normalizing makes duplicates worse.
#
#   Only *_ALIAS / NEVER_UNIT / TRANSPOSE_WORDS params are names. The *_REPLACE types
#   store REGEXES in param_1 (source-URL gate) and param_2 (search pattern) - lowercasing
#   those would corrupt character classes like \S or \W, so they are left alone.
#
# RE-RUN THIS. It is idempotent. Tandoor's importer is case-sensitive on create, and no
# automation type can force lowercase, so fresh imports keep reintroducing capitals.
#
# Usage:
#   ./tandoor-normalize-lowercase.sh           # dry run
#   ./tandoor-normalize-lowercase.sh --apply   # back up, then rename
#
set -euo pipefail

WEB_CONTAINER="${TANDOOR_WEB_CONTAINER:-tandoor}"
DB_CONTAINER="${TANDOOR_DB_CONTAINER:-tandoor_db}"
DB_USER="${TANDOOR_DB_USER:-djangouser}"
DB_NAME="${TANDOOR_DB_NAME:-djangodb}"
BACKUP_DIR="${TANDOOR_BACKUP_DIR:-/home/brad/docker/backups/tandoor}"
PYBIN="/opt/recipes/venv/bin/python"

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
  [[ -s "$BACKUP" ]] || { echo "ERROR: backup is empty, refusing to continue" >&2; exit 1; }
  echo "    $(du -h "$BACKUP" | cut -f1)"
  echo "    restore: docker exec -i $DB_CONTAINER pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists < $BACKUP"
else
  echo "==> DRY RUN (pass --apply to rename)"
fi

docker exec -i -e APPLY="$APPLY" -w /opt/recipes "$WEB_CONTAINER" "$PYBIN" manage.py shell <<'PY'
import os
from django.db.models import Count, F
from django.db.models.functions import Lower
from django.core.cache import caches
from django_scopes import scopes_disabled
from cookbook.models import Food, Unit, Keyword, Automation

apply = os.environ.get('APPLY') == '1'

# param_1/param_2 hold NAMES for these types. All *_REPLACE types hold regexes - never touch.
NAME_TYPES = ['FOOD_ALIAS', 'UNIT_ALIAS', 'KEYWORD_ALIAS', 'NEVER_UNIT', 'TRANSPOSE_WORDS']
MODELS = [('food', Food), ('unit', Unit), ('keyword', Keyword)]

with scopes_disabled():
    # ---- collision check: two names collapsing onto one lowercase value would violate
    # the (space_id, name) unique constraint, so bail rather than crash mid-update.
    blocked = False
    for label, M in MODELS:
        dupes = (M.objects.annotate(lc=Lower('name')).values('lc')
                 .annotate(n=Count('id')).filter(n__gt=1).order_by('-n'))
        for d in dupes:
            names = list(M.objects.annotate(lc=Lower('name'))
                         .filter(lc=d['lc']).values_list('name', flat=True))
            print("COLLISION %s: %s -> %r (needs a merge first)" % (label, names, d['lc']))
            blocked = True

    def upper_count(M, field):
        return M.objects.filter(**{f'{field}__isnull': False}) \
                .exclude(**{field: Lower(field)}).count()

    print("--- to lowercase ---")
    for label, M in MODELS:
        fields = [f.name for f in M._meta.get_fields()
                  if getattr(f, 'attname', None) in ('name', 'plural_name')]
        for field in fields:
            print("  %-8s %-12s %d" % (label, field, upper_count(M, field)))
    for t in NAME_TYPES:
        n = (Automation.objects.filter(type=t).exclude(param_1=Lower('param_1')).count()
             + Automation.objects.filter(type=t, param_2__isnull=False)
               .exclude(param_2=Lower('param_2')).count())
        if n:
            print("  %-8s %-12s %d" % ('automation', t, n))

    if blocked:
        raise SystemExit("\nABORT: merge the colliding names first, then re-run.")

    if not apply:
        print("\n(dry run - nothing written)")
        raise SystemExit(0)

    print("\n--- applying ---")
    for label, M in MODELS:
        fields = [f.name for f in M._meta.get_fields()
                  if getattr(f, 'attname', None) in ('name', 'plural_name')]
        for field in fields:
            n = (M.objects.filter(**{f'{field}__isnull': False})
                 .exclude(**{field: Lower(field)})
                 .update(**{field: Lower(field)}))
            print("  %-8s %-12s %d renamed" % (label, field, n))

    for field in ('param_1', 'param_2'):
        n = (Automation.objects.filter(type__in=NAME_TYPES, **{f'{field}__isnull': False})
             .exclude(**{field: Lower(field)}).update(**{field: Lower(field)}))
        print("  %-8s %-12s %d renamed" % ('automation', field, n))

    caches['default'].clear()   # Unit post_save normally clears the base-unit cache

    # ---- verification
    print("\n--- verify ---")
    for label, M in MODELS:
        fields = [f.name for f in M._meta.get_fields()
                  if getattr(f, 'attname', None) in ('name', 'plural_name')]
        for field in fields:
            print("  %-8s %-12s %d still uppercase" % (label, field, upper_count(M, field)))

    # Alias targets that do not resolve to a real record will CREATE one on next import.
    for t, M in (('FOOD_ALIAS', Food), ('UNIT_ALIAS', Unit), ('KEYWORD_ALIAS', Keyword)):
        names = set(M.objects.values_list('name', flat=True))
        bad = sorted({a.param_2 for a in Automation.objects.filter(type=t)
                      if a.param_2 and a.param_2 not in names})
        print("  %s targets with no matching record: %d%s"
              % (t, len(bad), (" -> " + ", ".join(bad[:8])) if bad else ""))

    # get_food() matches name OR plural_name and takes .first() - overlap is ambiguous.
    fnames = dict(Food.objects.values_list('name', 'id'))
    amb = [(p, n) for p, n in Food.objects.filter(plural_name__isnull=False)
           .values_list('plural_name', 'name') if p in fnames and p != n]
    print("  plural_name colliding with another food's name: %d%s"
          % (len(amb), (" -> " + str(amb[:5])) if amb else ""))
PY

echo "==> Done"
