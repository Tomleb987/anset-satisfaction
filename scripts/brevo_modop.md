# Mode opératoire — Connexion Brevo (sondage satisfaction ANSET)

**Destinataire : Lionel — Service informatique**
**Objet : activer l'envoi automatique des e-mails d'invitation au sondage de satisfaction.**

## Contexte en 30 secondes

Le sondage de satisfaction fonctionne ainsi :
1. Chaque mois, un manager importe la liste des clients dans l'app de pilotage → table `envois_sondage` (Supabase).
2. Une **Edge Function Supabase** `envoi-sondage` envoie un e-mail personnalisé à chaque client **via Brevo**.
3. Le client clique, répond, et la réponse remonte dans le dashboard.

**Ton rôle** : brancher Brevo (compte + **clé SMTP**) et renseigner 5 « secrets » côté Supabase. Le code est déjà déployé, rien à développer. **Pas de modèle d'e-mail à créer** : le HTML est embarqué dans la fonction.

- Projet Supabase : **`xizitftoejfxaizztzeu`** (région eu-west-1, UE)
- App / formulaire : https://anset-satisfaction.vercel.app
- Aperçu de l'e-mail envoyé : dépôt GitHub `Tomleb987/anset-satisfaction` → `scripts/brevo_invitation.html`

> **Pourquoi SMTP et pas l'API Brevo ?** L'API Brevo refuse les appels venant d'une IP inconnue, et
> l'IP de sortie des Edge Functions Supabase change à chaque invocation : impossible de la mettre en
> liste blanche. Le **relais SMTP** de Brevo n'applique pas ce filtrage → on garde la sécurité IP
> activée sur le compte et l'envoi fonctionne.

---

## Étape 1 — Compte Brevo & délivrabilité

1. Créer / utiliser le compte **Brevo** d'ANSET : https://www.brevo.com (offre gratuite ≈ 300 e-mails/jour, suffisante pour démarrer ; passer à un plan payant si volume mensuel > 9 000).
2. **Expéditeur** : *Settings → Senders, Domains & Dedicated IPs → Senders* → ajouter et **valider** une adresse d'envoi, ex. `assurances@anset.pf` (un e-mail de validation est envoyé).
3. **Délivrabilité (important, ton domaine)** : *Domains* → authentifier le domaine `anset.pf` en publiant les enregistrements **SPF** et **DKIM** fournis par Brevo dans la zone DNS d'ANSET. Sans ça, les e-mails risquent le dossier spam.

## Étape 2 — Clé SMTP

1. *Settings → SMTP & API → onglet **SMTP***.
2. Relever **deux** valeurs :
   - le **Login** (généralement l'adresse du compte Brevo, parfois un identifiant du type
     `xxxxxxx@smtp-brevo.com`) ;
   - la **clé SMTP** (*SMTP key / master password*) → *Generate a new SMTP key* si aucune n'est
     affichée. Format `xsmtpsib-…`. **À garder secrète.**
3. Serveur d'envoi : `smtp-relay.brevo.com`, port `587` (STARTTLS). Ce sont les valeurs par défaut
   du code : rien à saisir, sauf si Brevo t'indique autre chose (voir étape 4, secrets optionnels).

> ⚠️ Ne **pas** utiliser une clé **API** (`xkeysib-…`) : c'est elle qui est soumise au filtrage IP
> (encadré « Pourquoi SMTP » en haut de ce document).

## Étape 3 — Modèle d'e-mail : rien à faire

Le relais SMTP n'utilise pas les templates transactionnels Brevo : le **sujet et le HTML de
l'invitation sont embarqués dans le code** de la fonction
(`supabase/functions/envoi-sondage/email.ts`). Un aperçu lisible du rendu se trouve dans
`scripts/brevo_invitation.html`.

- Sujet envoyé : **Votre avis sur ANSET en 1 minute**
- Le lien personnalisé de chaque client est inséré par la fonction (bouton « Donner mon avis » +
  lien de secours en clair, pour les clients mail qui bloquent les boutons).
- L'e-mail est générique (« Ia Ora Na, », pas de prénom) et porte la mention RGPD + contact DPO.
- Faire évoluer le visuel = modifier `email.ts` puis redéployer la fonction (côté projet, Thomas).

## Étape 4 — Renseigner les 5 secrets Supabase

Ces valeurs sont lues par la fonction `envoi-sondage`. **Deux méthodes** au choix.

### Méthode A — Dashboard Supabase (recommandée, sans outil)
1. Ouvrir : https://supabase.com/dashboard/project/xizitftoejfxaizztzeu/settings/functions
   *(Project Settings → Edge Functions → section « Secrets » / « Add new secret »)*
2. Ajouter les clés suivantes :

| Nom du secret | Valeur |
|---|---|
| `BREVO_SMTP_LOGIN` | le **login SMTP** de l'étape 2 |
| `BREVO_SMTP_KEY` | la **clé SMTP** `xsmtpsib-…` de l'étape 2 |
| `FORM_URL` | `https://anset-satisfaction.vercel.app/sondage` |
| `BREVO_SENDER_EMAIL` | `assurances@anset.pf` (l'expéditeur validé à l'étape 1) |
| `BREVO_SENDER_NAME` | `ANSET` |

3. Enregistrer. (La prise en compte est immédiate au prochain appel de la fonction.)

Secrets **optionnels**, uniquement en cas de souci réseau : `BREVO_SMTP_HOST` (défaut
`smtp-relay.brevo.com`) et `BREVO_SMTP_PORT` (défaut `587` ; mettre `465` si le 587 est filtré —
le code bascule alors automatiquement en TLS direct).

Les anciens secrets `BREVO_API_KEY` et `BREVO_TEMPLATE_ID` **ne servent plus** : tu peux les
supprimer (ou laisser, ils sont ignorés).

### Méthode B — CLI Supabase (si tu préfères le terminal)
```bash
supabase login                                  # token depuis dashboard → Account → Access Tokens
supabase link --project-ref xizitftoejfxaizztzeu
supabase secrets set \
  BREVO_SMTP_LOGIN=contact@anset.pf \
  BREVO_SMTP_KEY=xsmtpsib-xxxxxxxx \
  FORM_URL=https://anset-satisfaction.vercel.app/sondage \
  BREVO_SENDER_EMAIL=assurances@anset.pf \
  BREVO_SENDER_NAME="ANSET"
```

## Étape 4 bis — Sécurité IP Brevo : rien à désactiver

C'est tout l'intérêt du passage en SMTP. Le blocage « *We have detected you are using an
unrecognised IP address…* » ne concerne que l'**API**. Le relais SMTP s'authentifie par login + clé
SMTP, sans contrôle d'IP.

- **Laisser « Block unknown IP addresses » ACTIVÉ** sur https://app.brevo.com/security/authorised_ips.
- Si cette option avait été désactivée pour faire fonctionner l'ancienne version par API, tu peux
  la **réactiver**.
- La clé SMTP ne vit que dans les secrets Supabase (jamais dans le dépôt, jamais dans le HTML
  public) et reste révocable/rotable en un clic depuis *SMTP & API → onglet SMTP*.

## Étape 5 — Test de bout en bout

Depuis l'app de pilotage : https://anset-satisfaction.vercel.app/satisfaction_anset
→ se connecter → onglet **Administration → Diffusion des invitations** :

1. **Aperçu (aucun envoi)** : vérifie que le lot est prêt et affiche un exemple de lien. *(Aucun e-mail parti.)*
2. **Test (1 e-mail)** : saisir ta propre adresse → tu dois recevoir l'e-mail « Ia Ora Na » avec le bouton « Donner mon avis ». Clique → le formulaire s'ouvre.
3. **Envoi réel** : lance la diffusion de la campagne. Les e-mails partent **immédiatement**, un par
   un (le SMTP ne sait pas programmer un envoi ; l'ancien décalage « H+2 » n'existe plus).

## Vérifications / dépannage

- **Rien ne part / erreur config** : un des 5 secrets est manquant ou mal orthographié (respecter les noms exacts, en MAJUSCULES).
- **« Invalid login » / « authentication failed »** : `BREVO_SMTP_LOGIN` ou `BREVO_SMTP_KEY` incorrect —
  attention à ne pas coller une clé **API** (`xkeysib-…`) à la place de la clé **SMTP** (`xsmtpsib-…`),
  et à ne pas laisser d'espace en fin de valeur.
- **« Sender not valid » / e-mail refusé** : l'adresse de `BREVO_SENDER_EMAIL` n'est pas validée dans
  Brevo (étape 1.2).
- **Timeout / connexion impossible** : le port 587 est filtré → mettre le secret `BREVO_SMTP_PORT=465`.
- **Envoi réel partiel** (`envoyes` < lot, `echecs` > 0) : les lignes en échec restent `a_envoyer` — il
  suffit de relancer « Envoi réel » après correction, aucun doublon (la fonction est idempotente).
  Attention aussi au quota du plan (≈ 300 e-mails/jour en gratuit) : au-delà, Brevo refuse les envois.
- **E-mails en spam** : authentifier le domaine (SPF/DKIM, étape 1.3).
- **Le lien du bouton est vide** : problème côté données (`envois_sondage` sans référence) ou `FORM_URL`
  mal renseigné → le vérifier avec « Aperçu (aucun envoi) », qui affiche un exemple de lien.
- **Logs** : Supabase → *Edge Functions → envoi-sondage → Logs* pour voir le détail des erreurs.

## Ce que tu n'as PAS à faire
- Aucun développement : les fonctions et le formulaire sont déjà déployés.
- L'anti-spam du formulaire (Cloudflare Turnstile) est déjà configuré.
- La base de données et les imports sont opérationnels.

---
*Contact projet : Thomas (thomas@anset.pf). RGPD : dpo@anset.pf.*
