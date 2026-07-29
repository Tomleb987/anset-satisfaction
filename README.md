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
    admin-utilisateurs/index.ts                  # comptes d'accès (super admin only) : créer/rôle/désactiver
  migrations/
    20260723090200_base_schema.sql               # FONDATEUR : conseillers, reponses_satisfaction, leads, lead_notes, v_satisfaction_agence
    20260723090300_agences.sql                  # table agences (code -> nom/zone) + seed
    20260723090400_envois_sondage.sql            # table envois_sondage + enum envoi_statut + RLS
    20260723090500_reponses_dashboard.sql        # attribution + vues réseau/zone/conseiller/taux/verbatims
    20260723090600_rls_app.sql                   # policies RLS applicatives (authenticated)
    20260724120000_motif_sinistre.sql            # motif + mesures sinistre + vue v_satisfaction_motif
    20260729120000_profils_utilisateurs.sql      # table profils (roles super_admin/manager) + amorçage
scripts/
  purge_rgpd.sql                                # cron mensuel de purge des leads sans_suite/ne_pas_contacter
  desactivation_surveymonkey.md                  # état + actions (aucun cron déployé)
sondage.html                                    # formulaire public : interaction ? oui → agence, motif, [sinistre], accueil, conseiller, NPS, CSAT, réseaux sociaux, commentaire ; non → recontact direct. + Turnstile + RGPD
satisfaction_anset.html                          # app : Satisfaction (dont par motif + carte Sinistres) · Prospection · Administration (2 imports + diffusion) · Utilisateurs (super admin)
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

## Comptes et rôles

Table `profils` (une ligne par compte `auth.users`), deux rôles :

| Rôle | Peut |
|---|---|
| `manager` | Satisfaction, Prospection, imports, diffusion |
| `super_admin` | idem + onglet **Utilisateurs** (créer un compte, changer un rôle, désactiver, supprimer) |

Créer un compte exige l'API admin de Supabase, donc la `service_role` : tout passe par l'Edge
Function `admin-utilisateurs`, qui vérifie que l'appelant est `super_admin` **actif**. Le mot de passe
provisoire est généré côté serveur et affiché une seule fois. Un compte désactivé est banni côté auth
(connexion refusée, `user_banned`), son historique reste intact. On ne peut ni se rétrograder, ni se
désactiver, ni se supprimer soi-même, ni retirer le dernier super admin actif.

`profils` est en lecture pour tout compte connecté (l'app doit connaître son propre rôle) et **sans
policy d'écriture** : un manager ne peut donc pas se promouvoir.

## Diagnostic

- `envoi-sondage?dry=1` → aperçu du lot sans envoi. `?test=adresse@x.pf` → 1 invitation de test.
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
