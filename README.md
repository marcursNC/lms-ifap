# LMS IFAP — V13

Prototype applicatif connecté au projet Supabase **LMS-IFAP** (`yzrzcidecfojywfvnvtr`).

## V13
- Dashboard connecté aux données réelles
- Catalogue des formations connecté à Supabase
- Apprenants connectés à Supabase
- Sessions connectées à Supabase
- Attestations connectées à Supabase
- Navigation multi-organisation
- Déconnexion Supabase
- Création de formation via `/courses/new`

## Configuration
Copier `.env.example` vers `.env.local` et renseigner la clé publishable Supabase.

## Vérification
L'environnement local disponible ici ne dispose pas des dépendances npm installées et l'installation distante a dépassé le délai d'exécution. La compilation Next.js n'a donc pas pu être exécutée dans cet environnement.

Avant déploiement : `npm install` puis `npm run build`, tests RLS avec de vrais utilisateurs, SSO Entra ID, Storage/SCORM, import CSV, génération PDF et vérification QR.

## V15 — Inscriptions et présences
- Déploiement : gestion des inscriptions des apprenants.
- Apprenants : création d'agents dans une organisation.
- Session : roster, ajout d'inscrits et feuille de présence.
- Présence : upsert sur `(session_id, learner_id)`.
- Sécurité : visibilité des sessions limitée à l'organisation cible.
- Supabase security advisors : 0 alerte après migration V15.


## Microsoft Teams — synchronisation des présences

Le LMS peut synchroniser le rapport de présence d'une réunion Teams après sa fin. Microsoft Graph expose les `attendanceReports` et leurs `attendanceRecords`; le rapport est généré lorsque la réunion se termine.

Variables serveur : `MS_TENANT_ID`, `MS_CLIENT_ID`, `MS_CLIENT_SECRET`. L'application Entra ID doit disposer de la permission applicative adaptée aux artefacts de réunion, notamment `OnlineMeetingArtifact.Read.All`, avec consentement administrateur.

Dans une session LMS, renseigner `external_provider=microsoft_teams`, `external_meeting_id` et `external_organizer_user_id`, puis utiliser « Synchroniser Teams ». Le LMS rapproche les participants par adresse e-mail, calcule la durée cumulée et le pourcentage de présence.

Sources Microsoft Graph : https://learn.microsoft.com/en-us/graph/api/meetingattendancereport-list?view=graph-rest-1.0 et https://learn.microsoft.com/en-us/graph/api/attendancerecord-list?view=graph-rest-1.0
