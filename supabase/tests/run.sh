#!/bin/bash
# usage : PGHOST=... supabase/tests/run.sh [avant]
# Reconstruit une base jetable depuis les migrations puis joue les tests.
# « avant » : sans la migration de déploiement (les échecs sont attendus).
set -e
export PGOPTIONS="--client-min-messages=warning"
cd "$(dirname "$0")/.."
DB=test_deploiement; NOUVELLE=20261127000000_deploiement_organisations.sql
q(){ psql -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
dropdb --if-exists "$DB" 2>/dev/null; createdb "$DB"
q -f verification/stubs_supabase.sql -f tests/environnement.sql >/dev/null
for f in migrations/*.sql; do
  [ "$1" = avant ] && [ "$(basename "$f")" = "$NOUVELLE" ] && continue
  q -1 -f "$f" >/dev/null
done
q -f tests/deploiement.sql
