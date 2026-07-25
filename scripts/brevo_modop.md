# Mode opératoire — Connexion Brevo (sondage satisfaction ANSET)

**Destinataire : Lionel — Service informatique**
**Objet : activer l'envoi automatique des e-mails d'invitation au sondage de satisfaction.**

## Contexte en 30 secondes

Le sondage de satisfaction fonctionne ainsi :
1. Chaque mois, un manager importe la liste des clients dans l'app de pilotage → table `envois_sondage` (Supabase).
2. Une **Edge Function Supabase** `envoi-sondage` envoie un e-mail personnalisé à chaque client **via Brevo**.
3. Le client clique, répond, et la réponse remonte dans le dashboard.

**Ton rôle** : brancher Brevo (compte + clé API + un modèle d'e-mail) et renseigner 5 « secrets » côté Supabase. Le code est déjà déployé, rien à développer.

- Projet Supabase : **`xizitftoejfxaizztzeu`** (région eu-west-3, UE)
- App / formulaire : https://anset-satisfaction.vercel.app
- Modèle d'e-mail (HTML prêt) : dépôt GitHub `Tomleb987/anset-satisfaction` → `scripts/brevo_invitation.html`

---

## Étape 1 — Compte Brevo & délivrabilité

1. Créer / utiliser le compte **Brevo** d'ANSET : https://www.brevo.com (offre gratuite ≈ 300 e-mails/jour, suffisante pour démarrer ; passer à un plan payant si volume mensuel > 9 000).
2. **Expéditeur** : *Settings → Senders, Domains & Dedicated IPs → Senders* → ajouter et **valider** une adresse d'envoi, ex. `satisfaction@anset.pf` (un e-mail de validation est envoyé).
3. **Délivrabilité (important, ton domaine)** : *Domains* → authentifier le domaine `anset.pf` en publiant les enregistrements **SPF** et **DKIM** fournis par Brevo dans la zone DNS d'ANSET. Sans ça, les e-mails risquent le dossier spam.

## Étape 2 — Clé API

1. *Settings → SMTP & API → API Keys → Generate a new API key*.
2. Nommer la clé (ex. « sondage-satisfaction »), la copier.
   → format : `xkeysib-xxxxxxxx...`  **(à garder secrète)**.

## Étape 3 — Modèle d'e-mail (template transactionnel)

1. *Campaigns → Templates → onglet **Transactional** → Create a template*.
2. Renseigner :
   - **Template name** : `Invitation sondage ANSET`
   - **Subject** : `Votre avis sur ANSET en 1 minute`
   - **Preview text** : `Aidez-nous à améliorer nos services — c'est rapide et confidentiel.`
   - **From** : l'expéditeur validé à l'étape 1 (`satisfaction@anset.pf`, nom « ANSET »).
3. Choisir l'éditeur **« Code your own / HTML »**.
4. **Coller le contenu du fichier `scripts/brevo_invitation.html`** (dépôt GitHub) dans l'éditeur de code.
5. **Save & Activate** le template.
6. Relever son **ID** (nombre visible dans la liste des templates, ex. `3`).

> ⚠️ Le modèle contient la variable **`{{ params.lien }}`** (le lien personnalisé de chaque client). Ne pas la retirer : c'est elle qui rattache la réponse à la bonne agence / au bon conseiller. Il n'y a **pas** de personnalisation du prénom (e-mail générique « Ia Ora Na, »).

## Étape 4 — Renseigner les 5 secrets Supabase

Ces valeurs sont lues par la fonction `envoi-sondage`. **Deux méthodes** au choix.

### Méthode A — Dashboard Supabase (recommandée, sans outil)
1. Ouvrir : https://supabase.com/dashboard/project/xizitftoejfxaizztzeu/settings/functions
   *(Project Settings → Edge Functions → section « Secrets » / « Add new secret »)*
2. Ajouter les clés suivantes :

| Nom du secret | Valeur |
|---|---|
| `BREVO_API_KEY` | la clé `xkeysib-…` de l'étape 2 |
| `BREVO_TEMPLATE_ID` | l'ID du template de l'étape 3 (un nombre) |
| `FORM_URL` | `https://anset-satisfaction.vercel.app/sondage` |
| `BREVO_SENDER_EMAIL` | `satisfaction@anset.pf` (l'expéditeur validé) |
| `BREVO_SENDER_NAME` | `ANSET` |

3. Enregistrer. (La prise en compte est immédiate au prochain appel de la fonction.)

### Méthode B — CLI Supabase (si tu préfères le terminal)
```bash
supabase login                                  # token depuis dashboard → Account → Access Tokens
supabase link --project-ref xizitftoejfxaizztzeu
supabase secrets set \
  BREVO_API_KEY=xkeysib-xxxxxxxx \
  BREVO_TEMPLATE_ID=3 \
  FORM_URL=https://anset-satisfaction.vercel.app/sondage \
  BREVO_SENDER_EMAIL=satisfaction@anset.pf \
  BREVO_SENDER_NAME="ANSET"
```

## Étape 5 — Test de bout en bout

Depuis l'app de pilotage : https://anset-satisfaction.vercel.app/satisfaction_anset
→ se connecter → onglet **Administration → Diffusion des invitations** :

1. **Aperçu (aucun envoi)** : vérifie que le lot est prêt et affiche un exemple de lien. *(Aucun e-mail parti.)*
2. **Test (1 e-mail)** : saisir ta propre adresse → tu dois recevoir l'e-mail « Ia Ora Na » avec le bouton « Donner mon avis ». Clique → le formulaire s'ouvre.
3. **Envoi réel** : lance la diffusion de la campagne (programmée à H+2 côté Brevo).

## Vérifications / dépannage

- **Rien ne part / erreur config** : un des 5 secrets est manquant ou mal orthographié (respecter les noms exacts, en MAJUSCULES).
- **Erreur Brevo dans l'aperçu** : clé API invalide, ou expéditeur non validé, ou `BREVO_TEMPLATE_ID` incorrect.
- **E-mails en spam** : authentifier le domaine (SPF/DKIM, étape 1.3).
- **Le lien du bouton est vide** : la variable `{{ params.lien }}` a été supprimée du template → la remettre.
- **Logs** : Supabase → *Edge Functions → envoi-sondage → Logs* pour voir le détail des erreurs.

## Ce que tu n'as PAS à faire
- Aucun développement : les fonctions et le formulaire sont déjà déployés.
- L'anti-spam du formulaire (Cloudflare Turnstile) est déjà configuré.
- La base de données et les imports sont opérationnels.

---
*Contact projet : Thomas (thomas@anset.pf). RGPD : dpo@anset.pf.*
