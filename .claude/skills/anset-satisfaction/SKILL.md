---
name: anset-satisfaction
description: >
  Domaine métier ANSET Satisfaction & Prospection (remplace SurveyMonkey) : chaîne
  de collecte, modèle de données réel Supabase (noms de colonnes, enums, jsonb),
  RLS, anti-spam Turnstile, diffusion Brevo, et contraintes RGPD. À charger AVANT
  de toucher aux Edge Functions, migrations, au schéma, à la logique de sondage/lead,
  ou de raisonner sur consentement/rétention. Se déclenche sur : sondage, satisfaction,
  lead, prospection, recontact, consentement, RGPD, Turnstile, Brevo, envoi, campagne,
  conseiller, agence, Edge Function, migration, RLS, Supabase, response_id.
---

# ANSET — Satisfaction & Prospection (domaine)

Outil unique remplaçant SurveyMonkey. Projet Supabase `xizitftoejfxaizztzeu`,
région **eu-west-1 (UE)**. Voir `README.md` pour la mise en service détaillée.

## Chaîne de collecte

```
sondage.html (public, statique)
  │ POST { réponses, consentement, coordonnées, turnstileToken, params URL (req/conseiller/agence/zone/campagne) }
  ▼
Edge Function submit-sondage  (verify_jwt=false)
  │ 1. vérifie Turnstile (serveur) → sans token valide, AUCUNE écriture
  │ 2. mappe   3. écrit en service_role (bypass RLS)
  ▼
reponses_satisfaction (toujours)  +  leads (si consentement ET contact)
```

Diffusion mensuelle : import `.xlsx` → `envois_sondage` → Edge Function `envoi-sondage`
(Brevo, lien personnalisé, programmé H+2). Modes diag : `?dry=1`, `?test=x@y.pf`,
`?campagne=YYYY-MM`, `?limit=N`.

## Modèle de données réel (points sensibles — NE PAS deviner)

Les tables `reponses_satisfaction`, `leads`, `lead_notes`, `conseillers`, `sondage_sync`
**préexistent**. Le code est aligné sur leurs **vrais** noms de colonnes.

- `response_id` : **unique** sur `reponses_satisfaction` ET `leads` → upsert idempotent
  (une re-soumission ne duplique pas).
- `leads.conseiller_id` : **text**, FK → `conseillers.id` (slugs : `hina, teva, moana…`).
  Un slug d'URL invalide est **mis à null** côté fonction, jamais rejeté (ne pas casser l'insert).
- `reponses_satisfaction.conseiller_id` : **PAS de FK** (on ne perd jamais une réponse
  pour une contrainte) ; attribution par slug. Colonnes d'attribution : `req`,
  `conseiller_id`, `zone` (+ `campagne`, `agence`).
- `leads.consentement_source` : **jsonb** (preuve horodatée du consentement).
- Enum `lead_statut` : `nouveau, a_contacter, injoignable, rappel, interesse, devis,
  souscrit, sans_suite, ne_pas_contacter`.
- Enum `envoi_statut` (`envois_sondage.statut_envoi`) : inclut `envoye` (compté dans les taux).
- Réponses collectées : `interaction_recente, nps, nps_categorie, satisfaction_globale,
  note_conseiller, commentaire, a_consenti_recontact`. Colonnes non collectées = null (voulu).
- **Branche interaction** : toutes les questions de satisfaction (agence, motif, sinistre, accueil,
  conseiller, NPS, CSAT, réseaux sociaux, commentaire) sont conditionnées à `interaction = oui` dans
  `sondage.html` (attribut `data-cond="interaction"`). Un « Non » va **droit au recueil de recontact
  commercial**. `reseaux_sociaux` (slug `oui`/`interesse`/`non`) n'est peuplé que dans cette branche.
- **Motif** : `reponses_satisfaction.motif` + `envois_sondage.motif` (slug parmi
  `souscription, sinistre, gestion, reclamation, information, autre`). Demandé au client pour la
  requête générale ; **imposé** (via `?motif=` dans le lien) pour les campagnes typées. Le motif de
  l'envoi (`envois_sondage.motif`) **fait foi** dans `submit-sondage` s'il est présent.
- **Sinistre** : `sat_sinistre` + `delai_indemnisation` (smallint 1-5) — remplis **uniquement** si
  `motif='sinistre'`. Second import mensuel « sinistres clos » (`num_sinistre`→req, `gestionnaire`=slug
  conseiller, `portable`=tél, **pas d'agence**) → `envois_sondage` avec `motif='sinistre'`. À importer
  **après** la requête générale ; un client déjà présent est re-taggé `sinistre` (agence conservée).

## Sécurité & RLS

- RLS active sur les tables ; policies `authenticated` (lecture dashboard + écritures
  prospection) définies dans `20260723090600_rls_app.sql`. **Les écritures serveur
  passent en service_role et bypassent la RLS** — ne pas ajouter de policy pour elles.
- `submit-sondage` est public (`verify_jwt=false`) ; `envoi-sondage` exige un JWT.
- Toute PII (leads, verbatims nominatifs) reste **derrière login**.
- Migrations : **additives et idempotentes** (`add column if not exists`,
  `create or replace`, `drop policy if exists` avant `create policy`).

## RGPD (contraintes fortes)

- **Hébergement UE**, aucun transfert hors UE. SurveyMonkey abandonné → token à révoquer
  (voir `scripts/desactivation_surveymonkey.md`).
- **Consentement recontact explicite** : case non pré-cochée ; un lead n'est créé **que**
  si `a_consenti_recontact` ET coordonnées présentes. Preuve dans `consentement_source`.
- **Minimisation** : formulaire volontairement court (pas de secteur, pas d'adresse
  postale). Ne pas ajouter de champ PII sans justification.
- **Purge** : `scripts/purge_rgpd.sql` (cron mensuel — supprime leads `sans_suite` /
  `ne_pas_contacter` au-delà du délai de conservation).

## À vérifier avant de dire « fait »

Le code local peut être en avance sur le déploiement. Ne pas affirmer qu'une migration
est poussée, une fonction déployée ou un secret posé sans l'avoir confirmé. Secrets requis :
`TURNSTILE_SECRET`, `BREVO_API_KEY`, `BREVO_TEMPLATE_ID`, `BREVO_SENDER_EMAIL`,
`BREVO_SENDER_NAME`, `FORM_URL` (+ `ALLOWED_ORIGIN` optionnel). Côté `sondage.html`,
la clé publique Turnstile `data-sitekey` doit être renseignée (placeholder par défaut).
