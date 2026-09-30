# Architecture V5

## Source de vérité
Le LMS porte l’état métier : organisations, formations, déploiements, inscriptions, sessions, progression, évaluations et attestations.

## n8n
n8n orchestre les intégrations (Ammon, Microsoft 365, SharePoint, Teams). Le LMS publie des événements via `event_outbox`; n8n consomme les événements et reste idempotent.

## Événements
`learner.created`, `enrollment.created`, `course.completed`, `evaluation.passed`, `session.completed`, `certificate.issued`.

## Sécurité
Les webhooks utilisent une signature HMAC. En production, ajouter rotation des secrets, anti-rejeu, journalisation et contrôle strict des permissions.

## Virtual classroom tracking

The LMS exposes `POST /api/webhooks/virtual-classroom` for provider-neutral attendance events. Requests must carry an HMAC-SHA256 signature in `x-lms-signature`. The route is idempotent using the provider/external event ID, stores the raw event for auditability, matches participants to active learners by email or external reference, and updates attendance join/leave timestamps and duration.

Microsoft Teams can be connected through Microsoft Graph subscriptions or an intermediary such as n8n. The LMS remains the source of truth for enrollment, attendance and completion; Teams/Zoom/Webex only provide meeting events.
