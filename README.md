# ANSET — Satisfaction & Prospection

Collecte de satisfaction **sans SurveyMonkey** : un formulaire HTML court écrit dans Supabase
via une Edge Function. Fusionne l'analyse satisfaction (managers) et la prospection/recontact
(conseillers) dans un seul outil. Projet Supabase `xizitftoejfxaizztzeu` — région `eu-west-1` (UE).

## Chaîne

```
sondage.html (public, hébergé statique)
   │  POST { réponses, consentement, coordonnées, turnstileToken, params URL }
   ▼
Edge Function submit-sondage (public, verify_jwt=false)
   │  1. vérifie Turnstile (anti-spam, serveur)  2. mappe  3. écrit via service_role
   ▼
reponses_satisfaction (toujours)  +  leads (si consentement & contact)
```

Diffusion mensuelle : import de la « requête » `.xlsx` → table `envois_sondage` → Edge Function
`envoi-sondage` (relais **SMTP** Brevo, lien personnalisé, départ immédiat). Un **second import** mensuel — la liste
des **sinistres clos** `.xlsx` — alimente les mêmes `envois_sondage` avec `motif='sinistre'` : ces
clients reçoivent le questionnaire **adapté sinistre** (2 questions en plus). Le lien porte alors
`?motif=sinistre` et le questionnaire pré-remplit / masque la question du motif.

Le **motif d'interaction** (souscription · sinistre · gestion de contrat · réclamation · information ·
autre) est demandé au répondant pour la requête générale, et **imposé** pour les campagnes typées.

## Arborescence

```
supabase/
  config.toml                                   # verify_jwt: submit-sondage=false, autres=true
  functions/
    submit-sondage/index.ts                     # form -> Turnstile -> reponses_satisfaction + leads
    envoi-sondage/index.ts                       # envois_sondage -> SMTP Brevo (modes ?test / ?dry)
    envoi-sondage/email.ts                       # sujet + HTML de l'invitation (source de vérité)
    admin-utilisateurs/index.ts                  # comptes d'accès (super admin only) : créer/rôle/rattachement/désactiver
  migrations/
    20260723090200_base_schema.sql               # FONDATEUR : conseillers, reponses_satisfaction, leads, lead_notes, v_satisfaction_agence
    20260723090300_agences.sql                  # table agences (code -> nom/zone) + seed
    20260723090400_envois_sondage.sql            # table envois_sondage + enum envoi_statut + RLS
    20260723090500_reponses_dashboard.sql        # attribution + vues réseau/zone/conseiller/taux/verbatims
    20260723090600_rls_app.sql                   # policies RLS applicatives (authenticated)
    20260724120000_motif_sinistre.sql            # motif + mesures sinistre + vue v_satisfaction_motif
    20260729120000_profils_utilisateurs.sql      # table profils (roles super_admin/manager) + amorçage
    20260729130000_admin_reserve_super_admin.sql # est_super_admin() + écritures envois/conseillers réservées
    20260730100000_role_conseiller.sql           # rôle conseiller : profils.conseiller_id + RLS par périmètre
    20260730120000_relance_j7.sql                # date_relance + vue v_relances_a_faire (file du rappel J+7)
scripts/
  creer_comptes.mjs                             # création en masse des comptes (managers nommés, reste en conseiller)
  relance_j7_cron.sql                           # à jouer une fois : pg_cron quotidien qui déclenche la relance
  purge_rgpd.sql                                # cron mensuel de purge des leads sans_suite/ne_pas_contacter
  desactivation_surveymonkey.md                  # état + actions (aucun cron déployé)
sondage.html                                    # formulaire public : interaction ? oui → agence, motif, [sinistre], accueil, conseiller, NPS, CSAT, réseaux sociaux, commentaire ; non → recontact direct. + Turnstile + RGPD
satisfaction_anset.html                          # app : Satisfaction · Prospection · [super admin] Administration (2 imports + diffusion) · Utilisateurs
```

> Projet Supabase `xizitftoejfxaizztzeu` (région `eu-west-1`, UE), configuré lors d'une session
> précédente (tables de base et fonctions déjà présentes). La migration `20260723090200_base_schema.sql`
> est **idempotente** (`create table if not exists`, `create or replace`) : elle garantit le schéma
> fondateur (`conseillers`, `reponses_satisfaction`, `leads`, `lead_notes`, enum `lead_statut`, vue
> `v_satisfaction_agence`) sans casser l'existant ; les migrations suivantes l'enrichissent.

## Schéma réel (rappel des points sensibles)

- `leads.conseiller_id` **text**, FK → `conseillers.id` (slugs : `hina, teva, moana, …`) → un slug d'URL
  invalide est ignoré (mis à null) côté fonction pour ne pas casser l'insert.
- `leads.consentement_source` **jsonb** ; `response_id` **unique** sur les 2 tables (upsert OK).
- enum `lead_statut` : `nouveau, a_contacter, injoignable, rappel, interesse, devis, souscrit, sans_suite, ne_pas_contacter`.
- `reponses_satisfaction` : `interaction_recente, nps, nps_categorie, satisfaction_globale, note_conseiller,
  commentaire, a_consenti_recontact` (+ colonnes non collectées laissées null).
- **Motif & sinistre** (migration `20260724120000`) : `reponses_satisfaction.motif` (slug parmi les 6),
  `sat_sinistre` / `delai_indemnisation` (smallint 1-5, non nuls seulement si `motif='sinistre'`) ;
  `envois_sondage.motif` (renseigné `'sinistre'` par l'import sinistres clos). Vue
  `v_satisfaction_motif` (campagne × motif) → bloc « par motif » + carte Sinistres du dashboard.
- Import **sinistres clos** : pas de colonne agence ; `gestionnaire` = slug conseiller ; `portable` = tél ;
  `num_sinistre` = req. Un client déjà dans la requête du mois est basculé en `motif='sinistre'` (agence conservée).
- **Branche interaction** : si le répondant déclare **aucune interaction récente**, le formulaire saute
  directement au recueil de recontact commercial (toutes les questions de satisfaction sont conditionnées
  à `interaction = oui`). `reponses_satisfaction.reseaux_sociaux` (slug `oui`/`interesse`/`non`, migration
  `20260724130000`) capture le suivi de la marque sur les réseaux sociaux (branche interaction seulement).

## Mise en service

1. **Migrations** : `supabase db push` (applique `agences` + `envois_sondage` ; additif, idempotent).
2. **Fonctions** :
   ```
   supabase functions deploy submit-sondage --no-verify-jwt
   supabase functions deploy envoi-sondage
   supabase functions deploy admin-utilisateurs
   ```
3. **Secrets** :
   ```
   supabase secrets set TURNSTILE_SECRET=…            # Cloudflare Turnstile (clé secrète)
   supabase secrets set BREVO_SMTP_LOGIN=… BREVO_SMTP_KEY=…   # SMTP & API -> onglet SMTP
   supabase secrets set FORM_URL=https://…/sondage.html
   supabase secrets set BREVO_SENDER_EMAIL=… BREVO_SENDER_NAME="ANSET"
   # optionnels : BREVO_SMTP_HOST (défaut smtp-relay.brevo.com), BREVO_SMTP_PORT (défaut 587),
   #              BREVO_SMTP_CONCURRENCE (défaut 4 connexions simultanées),
   #              ALLOWED_ORIGIN=https://votre-hebergement   (CORS de submit-sondage)
   ```
   > L'envoi passe par le **relais SMTP** et non par l'API Brevo : l'API refuse les appels venant
   > d'une IP inconnue, or l'IP de sortie des Edge Functions change à chaque invocation. Les clés
   > SMTP ne subissent pas ce filtrage. `BREVO_API_KEY` / `BREVO_TEMPLATE_ID` ne servent plus.
4. **Formulaire** : héberger `sondage.html` (GitHub Pages / Vercel) ; renseigner `TURNSTILE_SITEKEY`
   (clé site publique) dans le `<div class="cf-turnstile" data-sitekey="…">` **et** le commentaire de config.
   `SUBMIT_URL` est déjà pointé sur la fonction.
5. **App** : `SB_ANON` est déjà renseignée (clé publishable). Le **premier** compte se crée dans
   Supabase (Authentication → Users) ; la migration `profils` en fait un `manager`, sauf
   `thomas@anset.pf` qui est amorcé `super_admin`. Ensuite tout passe par l'onglet **Utilisateurs**.
6. **Cron purge RGPD** : jouer `scripts/purge_rgpd.sql` (délai de conservation à valider).

## Relance J+7 des non-répondants

Un **seul** rappel par invitation, 7 jours après l'envoi, aux clients qui n'ont pas répondu.
Mode `?relance=1` de `envoi-sondage`, bouton **Relancer** dans l'onglet Administration.

- **La file est une vue**, `v_relances_a_faire` : envoi parti depuis ≥ 7 jours, jamais relancé,
  et aucune réponse *postérieure à cet envoi*. La comparaison porte sur `date_reponse >= date_envoi`
  et non sur la simple existence d'une réponse : un même `req` réapparaît d'une campagne à l'autre,
  une réponse du mois dernier ne prouve rien sur l'invitation en cours. **Le délai se change là et
  nulle part ailleurs** — l'app compte la file, elle ne la recalcule pas.
- **Un rappel et pas deux** : `envois_sondage.date_relance` est posée *avant* l'envoi, sous condition
  `date_relance is null`. Deux passages simultanés (le cron et un clic) ne peuvent pas doubler
  l'e-mail ; un échec SMTP remet la date à null, jamais le statut d'envoi.
- **Pas de statut `relance` dans l'enum** : `statut_envoi='envoye'` est le dénominateur du taux de
  réponse. Sortir les relancés de ce compte ferait bondir le taux sans une réponse de plus.
- **Périmètre global, pas mensuel** : sans `?campagne=`, la relance porte sur toutes les campagnes —
  un lot parti le 28 se relance le 4 du mois suivant.
- **Automatisation** : `scripts/relance_j7_cron.sql`, à jouer une fois dans le SQL Editor (pg_cron +
  pg_net, clé `service_role` rangée dans Vault). Sans lui la relance reste manuelle — et un rappel
  « à 7 jours » qui attend qu'on y pense n'en est pas un.

L'e-mail de rappel a son propre sujet et son propre texte (`email.ts`), et annonce explicitement
qu'il est le seul. Les deux e-mails partagent le même gabarit : les mentions RGPD ne vivent qu'à un
seul endroit.

## Comptes et rôles

Table `profils` (une ligne par compte `auth.users`), trois rôles :

| Rôle | Peut |
|---|---|
| `conseiller` | onglets **Mes résultats** (ses seules réponses, avec le réseau en repère) et **Prospection** |
| `manager` | onglets **Satisfaction** (réseau entier) et **Prospection** |
| `super_admin` | idem manager + **Administration** (imports, diffusion) et **Utilisateurs** (créer un compte, changer un rôle, désactiver, supprimer) |

### Le rôle `conseiller`

L'identifiant est le **login de la requête mensuelle** (colonne « Gestionnaire », ex.
`manon.marrocq`) : c'est déjà la clé de `conseillers.id` et la valeur portée par
`reponses_satisfaction.conseiller_id`. Le compte auth utilise `<login>@anset.pf` — la page de
connexion complète le domaine, un conseiller saisit son seul identifiant — mais le rattachement
qui fait foi est `profils.conseiller_id`, pas l'adresse.

Le cloisonnement est en base, pas à l'écran :

- `reponses_satisfaction` et `envois_sondage` ne rendent à un conseiller que les lignes portant son
  login (policies + `est_conseiller()` / `mon_conseiller_id()`, migration `20260730100000`). Toutes
  les vues du dashboard étant en `security_invoker`, elles se réduisent d'elles-mêmes — y compris
  pour un appel PostgREST depuis la console.
- **Exception assumée** : `v_satisfaction_reseau` est passée en `security_invoker = off`. C'est un
  agrégat par campagne, sans PII ni nom de collègue, et il sert de repère de comparaison sur
  « Mes résultats ». Sans cette exception la vue « réseau » renverrait au conseiller ses propres
  chiffres sous une étiquette réseau. **Ne jamais y ajouter de colonne nominative.**
- **Prospection : un conseiller voit tous les leads**, comme un manager (décision métier) — la file
  des leads non attribués doit rester prenable par n'importe qui.
- L'onglet **Satisfaction** lui est retiré : agrégé sur ses seules lignes, il afficherait ses
  chiffres sous des titres « réseau », « agence », « classement ».

Création en masse (une cinquantaine de comptes) : `node scripts/creer_comptes.mjs --dry` puis sans
`--dry`. Idempotent, il liste les managers nommément et crée tous les autres conseillers de la table.

L'espace **Administration** est fermé au manager côté serveur, pas seulement masqué : les policies
d'écriture de `envois_sondage` et `conseillers` exigent `public.est_super_admin()`, et `envoi-sondage`
renvoie 403 à un manager. Sans ça, un manager pouvait importer un fichier ou lancer une diffusion
depuis la console du navigateur.

Créer un compte exige l'API admin de Supabase, donc la `service_role` : tout passe par l'Edge
Function `admin-utilisateurs`, qui vérifie que l'appelant est `super_admin` **actif**. Le mot de passe
est soit **choisi** dans le formulaire (8 caractères minimum, jamais renvoyé par la fonction : il est
déjà connu de l'appelant et n'a rien à faire dans les logs de la passerelle), soit **généré** côté
serveur et affiché une seule fois. Un compte désactivé est banni côté auth
(connexion refusée, `user_banned`), son historique reste intact. On ne peut ni se rétrograder, ni se
désactiver, ni se supprimer soi-même, ni retirer le dernier super admin actif.

`profils` est en lecture pour tout compte connecté (l'app doit connaître son propre rôle) et **sans
policy d'écriture** : un manager ne peut donc pas se promouvoir.

## Diagnostic

- `envoi-sondage?dry=1` → aperçu du lot sans envoi. `?test=adresse@x.pf` → 1 invitation de test.
- `envoi-sondage?relance=1` → rappel J+7 (`&dry=1` pour compter sans envoyer). File du moment :
  `select count(*) from public.v_relances_a_faire;`
- `?campagne=YYYY-MM` cible une campagne ; `?limit=N` plafonne le lot par passage.
- Gros lot : la fonction parallélise puis **se relance elle-même** (`?chaine=N`) — un seul clic. Le
  compteur de l'onglet Administration lit l'avancement réel dans `envois_sondage`.
- Anti-sollicitation : à l'import, un client déjà invité depuis moins de `DELAI_SOLLICITATION_MOIS`
  (1 mois, constante de `satisfaction_anset.html`) est marqué `exclu` et n'est jamais renvoyé.

## Sécurité & RGPD

- Hébergement UE (`eu-west-1`). Aucun transfert hors UE (SurveyMonkey abandonné → token à révoquer).
- Consentement recontact explicite (case non pré-cochée), preuve horodatée dans `leads.consentement_source`.
- PII derrière login (RLS `authenticated`) ; la fonction écrit en service_role.
- Anti-spam Turnstile vérifié côté serveur : sans token valide, aucune écriture.
- Minimisation : formulaire réduit (pas de secteur, pas d'adresse postale) + purge périodique.
