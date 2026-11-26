# Base de données

## `migrations/`
- 32 fichiers : export exact de `supabase_migrations.schema_migrations` (production, 27/11/2026).
- `20261125000000_rattrapage_hors_historique.sql` : objets créés directement en base, sans migration enregistrée. Reconstitué depuis la production. Comprend l'effet de `database/patches/v38_function_search_path.sql`.
- `20261126184023_deploiement_organisations.sql` : déploiement vers une organisation. Appliquée en production. Retour arrière dans `rollback/`, tests par `tests/run.sh deploiement` sur une base jetable.
- `20261126194226_achevement_attestations.sql` : achèvement des formations et attestations calculés par la base. Appliquée en production. Tests par `tests/run.sh achevement`.
- `20261127000000_editeur_contenu.sql` : droits sur les contenus, bucket privé `course-resources`, retrait sans perte de trace, ordre et publication. **Pas encore appliquée en production.** Tests par `tests/run.sh contenu` ; retour arrière dans `rollback/` (colonnes et bucket conservés).

## Attention avant `supabase db push`
La production ne connaît pas la version `20261125000000` et ses objets existent déjà. La déclarer appliquée au préalable, sans exécuter le SQL :

    supabase migration repair --status applied 20261125000000

## Vérification
Rejeu des 33 fichiers sur une base PostgreSQL 16 vide (après `verification/stubs_supabase.sql`), puis comparaison avec la production (PostgreSQL 17) au moyen de `verification/empreinte_schema.sql` : 629 objets sur 629 identiques (fonctions, politiques RLS, déclencheurs, colonnes, contraintes, index, vues, types, activation RLS).

Non comparés : privilèges (GRANT), contenu des tables dont les compartiments de stockage, réglages du projet Supabase.

`database/schema.sql` est l'ancien schéma initial et ne reflète plus la base.
