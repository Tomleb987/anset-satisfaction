---
name: anset-webdesign
description: >
  Charte digitale ANSET et système de design pour ce projet (formulaire public
  sondage.html + app de pilotage satisfaction_anset.html). À charger AVANT
  d'écrire ou modifier du HTML/CSS/UI ici : couleurs de marque, typographie,
  composants (cartes-option, échelle NPS, tuiles KPI, chips, barres), mode
  clair/sombre, accessibilité, et les règles « pas de build / tout inline ».
  Se déclenche sur : design, UI, CSS, couleurs, charte, formulaire, dashboard,
  composant, dark mode, responsive, logo, police.
---

# Webdesign ANSET

Deux pages autonomes, **HTML/CSS/JS vanilla, zéro build, tout inline** (déployées en
statique sur Vercel). Ne pas introduire de framework, bundler ni CDN de composants.
Seule dépendance externe tolérée : le client Supabase JS et la police DM Sans dans
`satisfaction_anset.html`. Le formulaire public reste le plus léger possible.

## Palette de marque (charte)

Tokens CSS déjà en place — **réutiliser les variables, ne pas hardcoder un hex**.

| Rôle | Token | Clair | Notes |
|------|-------|-------|-------|
| Bleu ANSET | `--blue` | `#1C509D` | couleur primaire, boutons, sélection |
| Bleu foncé | `--blue-dark` | `#143a72` | hover / accent |
| Rouge TAHITI | `--red` | `#E83C30` | logo uniquement, pas en UI d'action |
| Ciel | `--ciel` | `#6A9BAF` | data-viz secondaire |
| Corail | `--corail` | `#D36F6B` | négatif / détracteur |
| Moutarde | `--moutarde` | `#E69D46` | intermédiaire / passif |
| Menthe | `--menthe` | `#77AA92` | positif / promoteur |
| Mauve | `--mauve` | `#715689` | catégorie data-viz |

Sémantique data-viz : **promoteur = menthe, passif = moutarde, détracteur = corail**
(`--prom / --passif / --detr`). Voir le skill **anset-bi** pour les seuils.

## Typographie

- Police : **DM Sans** (fallback système). Mono : `ui-monospace, SFMono-Regular, Menlo`.
- Chiffres alignés : classe `.num` / `font-variant-numeric: tabular-nums` sur toute
  colonne ou KPI numérique.

## Mode clair / sombre

`satisfaction_anset.html` (app interne) **doit** rester bi-thème via
`@media (prefers-color-scheme: dark)` qui réassigne `--bg`, `--surface`, `--surface-2`,
`--border`, `--text`, `--muted`, `--blue*`. Toute nouvelle surface passe par ces tokens,
jamais un blanc/gris en dur — sinon elle casse en sombre.
`sondage.html` (public) est **clair uniquement** (fond `--cream #F7F9FC`), c'est voulu.

## Composants existants (réutiliser le motif, pas réinventer)

- **Rayon** : `--radius: 14px`. Bordures `1.5px solid var(--border)`.
- **Carte-option** (`.opt`) : sélectionnée → `.sel` (bordure bleue + fond `#eaf1fb`).
- **Échelle NPS** (`.scale button`) : carrés `aspect-ratio:1`, `.sel` = fond bleu plein.
- **Bouton** : `.btn.primary` (bleu plein), `.btn.ghost` (transparent/bordure). Poids 700.
- **Tuile KPI** (`.kpi`) : label en petites capitales `--muted`, valeur en `.num`,
  pied + sparkline. Deltas : `.up` menthe / `.down` corail / `.flat` muted.
- **Chip** (`.chip`) : pastille arrondie 999px pour statuts.
- **Barre horizontale** (`.hbar`) : `.track` + `.fill` colorée par le score.
- **Ombre** : toujours `var(--shadow)` (nulle en sombre).

## Règles

- **Copie FR**, ton sobre/administratif, vouvoiement. Pas d'anglais visible.
- **Accessibilité** : cible tactile ≥ 44px sur le formulaire mobile ; contraste AA ;
  `accent-color: var(--blue)` sur les inputs ; états focus visibles.
- **Responsive** : le formulaire est mobile-first (une question à la fois, barre de
  progression) ; l'app a des tableaux dans `.table-wrap { overflow-x:auto }` — jamais
  de scroll horizontal sur le `body`.
- **Échapper le HTML** injecté : utiliser le helper `esc()` déjà défini (verbatims,
  noms, commentaires viennent de saisies utilisateur).
- Le logo existe en 2 variantes : `anset_brand_logo_TAHITI.png` (fond clair) et
  `..._blanc.png` (fond foncé). Référence charte complète : `ANSET_Charte_digitale.pdf`.

## Pour une visualisation

Charger le skill global **dataviz** pour la méthode générale, puis appliquer la palette
et les seuils ANSET du skill **anset-bi**.
