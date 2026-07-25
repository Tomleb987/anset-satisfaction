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
2. **Expéditeur** : *Settings → Senders, Domains & Dedicated IPs → Senders* → ajouter et **valider** une adresse d'envoi, ex. `assurances@anset.pf` (un e-mail de validation est envoyé).
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
   - **From** : l'expéditeur validé à l'étape 1 (`assurances@anset.pf`, nom « ANSET »).
3. Choisir l'éditeur **« Code your own / HTML »**.
4. **Coller le HTML ci-dessous** dans l'éditeur de code (identique au fichier `scripts/brevo_invitation.html` du dépôt) :

```html
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F7F9FC;margin:0;padding:24px 0;font-family:'DM Sans',Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
  <tr><td align="center">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;background:#ffffff;border:1px solid #dde3ec;border-radius:16px;overflow:hidden;">
      <tr><td style="height:4px;background:#1C509D;background:linear-gradient(90deg,#1C509D,#715689);"></td></tr>
      <tr><td align="center" style="padding:28px 40px 8px;">
        <img src="https://anset-satisfaction.vercel.app/anset_brand_logo_TAHITI.png" alt="ANSET Assurances" width="150" style="display:block;height:auto;max-width:150px;" />
      </td></tr>
      <tr><td style="padding:8px 40px 0;">
        <h1 style="margin:16px 0 6px;font-size:22px;line-height:1.3;color:#16233c;font-weight:800;">Votre avis compte pour nous</h1>
        <p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#16233c;">Ia Ora Na,</p>
        <p style="margin:0 0 20px;font-size:15px;line-height:1.6;color:#5d6b83;">
          Chez <strong style="color:#16233c;">ANSET</strong>, votre satisfaction est notre priorité.
          Pourriez-vous prendre <strong style="color:#16233c;">une petite minute</strong> pour nous dire
          comment s'est passée votre expérience&nbsp;? Vos réponses nous aident à améliorer nos services au quotidien.
        </p>
      </td></tr>
      <tr><td align="center" style="padding:6px 40px 4px;">
        <table role="presentation" cellpadding="0" cellspacing="0"><tr>
          <td align="center" style="border-radius:12px;background:#1C509D;">
            <a href="{{ params.lien }}" target="_blank"
               style="display:inline-block;padding:15px 34px;font-size:16px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:12px;">
              Donner mon avis
            </a>
          </td>
        </tr></table>
      </td></tr>
      <tr><td align="center" style="padding:10px 40px 0;">
        <p style="margin:0;font-size:12.5px;color:#93a1b8;">Le questionnaire est court et confidentiel.</p>
      </td></tr>
      <tr><td style="padding:18px 40px 0;">
        <p style="margin:0;font-size:12px;line-height:1.5;color:#93a1b8;">
          Le bouton ne fonctionne pas&nbsp;? Copiez ce lien dans votre navigateur&nbsp;:<br>
          <a href="{{ params.lien }}" style="color:#1C509D;word-break:break-all;">{{ params.lien }}</a>
        </p>
      </td></tr>
      <tr><td style="padding:22px 40px 0;"><div style="border-top:1px solid #eef2f7;"></div></td></tr>
      <tr><td style="padding:16px 40px 30px;">
        <p style="margin:0;font-size:11.5px;line-height:1.6;color:#93a1b8;">
          Cet e-mail vous est adressé par <strong style="color:#5d6b83;">ANSET</strong> (responsable du traitement)
          dans le cadre de la mesure de la satisfaction client. Vos données sont hébergées dans l'Union européenne
          et conservées 12&nbsp;mois maximum. Vous disposez d'un droit d'accès, de rectification et de suppression&nbsp;:
          <a href="mailto:dpo@anset.pf" style="color:#1C509D;">dpo@anset.pf</a> ·
          <a href="https://www.anset.pf/assets/pdf/rgpd.pdf" style="color:#1C509D;">Politique de confidentialité</a>.
        </p>
      </td></tr>
    </table>
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;">
      <tr><td align="center" style="padding:16px 20px;">
        <p style="margin:0;font-size:11.5px;color:#93a1b8;font-family:'DM Sans',Segoe UI,Roboto,Arial,sans-serif;">
          ANSET Assurances — Tahiti, Polynésie française
        </p>
      </td></tr>
    </table>
  </td></tr>
</table>
```

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
| `BREVO_SENDER_EMAIL` | `assurances@anset.pf` (l'expéditeur validé) |
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
  BREVO_SENDER_EMAIL=assurances@anset.pf \
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
