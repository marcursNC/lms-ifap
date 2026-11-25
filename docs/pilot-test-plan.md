# Pilote fonctionnel LMS IFAP

## Objectif

Valider le parcours réel de bout en bout avec des comptes Supabase Auth réels, dans un environnement de test isolé de la production.

Le pilote ne doit pas être réalisé avec de simples UUID simulés : les essais RLS déjà effectués valident les règles PostgreSQL, mais ne valident ni l'envoi des liens de connexion, ni la création des sessions Auth, ni les parcours d'interface en conditions réelles.

## Pré-requis avant ouverture du pilote

- [ ] Confirmer que l'environnement utilisé est bien un environnement de test (projet Supabase séparé ou branche de développement), et non la base de production.
- [ ] Vérifier l'envoi des emails Supabase Auth (SMTP Resend) et la configuration des URL de redirection.
- [ ] Activer la protection contre les mots de passe compromis dans Supabase Auth si l'authentification par mot de passe est utilisée.
- [ ] Vérifier que les comptes de test utilisent des adresses contrôlées par les testeurs.
- [ ] Créer les utilisateurs via Supabase Auth Admin ou un flux d'invitation serveur sécurisé. Ne jamais insérer directement dans auth.users et ne jamais exposer la clé service_role au navigateur.
- [ ] Attribuer les rôles dans organization_members depuis un processus d'administration autorisé ; ne pas utiliser user_metadata pour les autorisations.
- [ ] Préparer un cours de test non sensible, une évaluation, une session et un déploiement dédiés au pilote.
- [ ] Prévoir des données fictives uniquement.

## Comptes à prévoir

| Compte | Organisation | Rôle | Vérifications |
|---|---|---|---|
| Administrateur IFAP | IFAP | org_admin | Créer/publier une formation IFAP, la déployer à une collectivité, consulter les indicateurs autorisés |
| Formateur IFAP | IFAP | trainer | Créer/mettre à jour une formation et gérer une session selon les droits définis |
| Administrateur collectivité | Collectivité de démonstration | org_admin | Gérer les apprenants et déployer une formation disponible |
| Apprenant collectivité A | Collectivité de démonstration | learner | Se connecter, suivre une formation, compléter une ressource, une activité et une évaluation |
| Apprenant collectivité B | Collectivité de démonstration | learner | Vérifier qu'il ne voit pas les données de l'apprenant A ni celles d'une autre organisation |

Un compte platform_admin peut être ajouté pour les vérifications techniques globales, mais il doit être réservé à un responsable habilité et ne doit pas servir aux tests ordinaires.

## Scénarios de recette

### 1. Authentification
- [ ] Recevoir un lien de connexion sur chaque adresse de test.
- [ ] Ouvrir le lien et arriver dans l'application sans retour intempestif à l'écran de connexion.
- [ ] Se déconnecter puis se reconnecter.
- [ ] Vérifier les URL de redirection et le comportement sur mobile.

### 2. Gestion IFAP et catalogue
- [ ] L'administrateur IFAP crée une formation en brouillon.
- [ ] Le formateur IFAP complète les modules et ressources.
- [ ] La formation est publiée dans le catalogue IFAP.
- [ ] L'administrateur IFAP la déploie pour la collectivité de démonstration.
- [ ] Vérifier qu'une organisation cliente ne peut pas modifier la formation source appartenant à IFAP.

### 3. Gestion collectivité
- [ ] L'administrateur collectivité consulte le déploiement qui lui est destiné.
- [ ] Il inscrit un apprenant ou configure le mode d'inscription retenu.
- [ ] Il consulte les inscriptions et le suivi de ses propres apprenants.
- [ ] Il ne voit aucune donnée d'une autre collectivité.

### 4. Parcours apprenant
- [ ] L'apprenant reçoit son accès et ouvre son espace.
- [ ] Il retrouve uniquement ses formations.
- [ ] Il ouvre une ressource et la marque terminée.
- [ ] Il termine un module.
- [ ] Il passe une évaluation.
- [ ] Le score est calculé côté serveur ; les bonnes réponses ne sont pas lisibles depuis le navigateur.
- [ ] Sa progression est recalculée correctement.

### 5. Session et présence
- [ ] L'apprenant inscrit voit sa session.
- [ ] Un apprenant non inscrit ne voit pas cette session.
- [ ] Le formateur ou l'administrateur enregistre une présence.
- [ ] Le taux de présence et l'état de validation sont cohérents.
- [ ] Pour un webinaire Teams, le rapport de présence est rapproché du bon apprenant et de la bonne session avant toute validation automatique.

### 6. Attestation
- [ ] L'attestation n'est délivrée qu'après satisfaction des conditions de complétion.
- [ ] Le PDF est téléchargeable par l'apprenant.
- [ ] L'employeur habilité peut télécharger l'attestation de son apprenant.
- [ ] Un utilisateur d'une autre organisation ne peut ni lire ni télécharger le document.
- [ ] La révocation éventuelle d'une attestation est prise en compte.

### 7. Accessibilité
- [ ] Navigation complète au clavier, sans piège de focus.
- [ ] Focus visible et ordre de tabulation logique.
- [ ] Libellés et erreurs compréhensibles avec lecteur d'écran.
- [ ] Contrastes suffisants et informations non transmises par la couleur seule.
- [ ] Zoom texte et affichage mobile utilisables.
- [ ] Préférence de réduction des animations respectée.
- [ ] Ressources vidéo/webinaire accompagnées de sous-titres ou d'une transcription lorsqu'elles sont disponibles.
- [ ] Les PDF d'attestation sont lisibles et structurés autant que possible.

## Critères d'acceptation

Le pilote est validé lorsque :
1. les cinq comptes peuvent se connecter réellement ;
2. chaque rôle peut effectuer uniquement les actions prévues ;
3. les deux apprenants ne peuvent pas accéder aux données de l'autre ;
4. l'apprenant suit le parcours jusqu'à l'attestation ;
5. les indicateurs et états de progression correspondent aux actions réalisées ;
6. aucun défaut bloquant d'accessibilité ou de sécurité n'est constaté.

Tout défaut doit être consigné avec : rôle utilisé, étape, résultat attendu, résultat observé, capture d'écran sans donnée personnelle, date et sévérité.

## Limite actuelle et prochaine action

Le connecteur Supabase disponible dans cet environnement permet d'interroger et de modifier la base, mais ne fournit pas d'action d'administration Auth permettant de créer/inviter proprement des utilisateurs. Il faut donc que le responsable Supabase habilité crée les cinq comptes dans Authentication > Users (ou qu'un flux d'invitation serveur sécurisé soit mis en place). Les comptes et leurs rôles ne doivent pas être créés en écrivant directement dans auth.users.

Aucune adresse email de test n'est présumée dans ce document. Aucun compte réel n'est créé par cette procédure.
