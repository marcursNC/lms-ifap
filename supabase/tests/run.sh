#!/bin/bash
# usage : PGHOST=... supabase/tests/run.sh [deploiement|achevement|contenu|scorm] [avant]
# Reconstruit une base jetable depuis les migrations puis joue les tests.
# « avant » : sans la migration testée ni les suivantes (les échecs sont attendus).
set -e
export PGOPTIONS="--client-min-messages=warning"
cd "$(dirname "$0")/.."
SUITE=${1:-deploiement}; DB=test_$SUITE
case $SUITE in
  deploiement) NOUVELLE=20261126184023_deploiement_organisations.sql ;;
  achevement) NOUVELLE=20261126194226_achevement_attestations.sql ;;
  contenu) NOUVELLE=20261126231243_editeur_contenu.sql ;;
  scorm) NOUVELLE=20261127001634_scorm_lecteur.sql ;;
  *) echo "suite inconnue : $SUITE" >&2; exit 2 ;;
esac
q(){ psql -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
dropdb --if-exists "$DB" 2>/dev/null; createdb "$DB"
q -f verification/stubs_supabase.sql -f tests/environnement.sql >/dev/null
for f in migrations/*.sql; do
  [ "$2" = avant ] && [[ ! "$(basename "$f")" < "$NOUVELLE" ]] && continue
  q -1 -f "$f" >/dev/null
done
q -f tests/$SUITE.sql
