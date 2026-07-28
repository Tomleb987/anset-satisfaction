---
name: anset-bi
description: >
  Pilotage & BI satisfaction ANSET : vues Supabase agrégées, formules NPS/CSAT,
  seuils de couleur, et helpers de graphiques SVG maison de satisfaction_anset.html.
  À charger AVANT de calculer un indicateur, ajouter un KPI/graphique au dashboard,
  écrire une vue SQL d'agrégation, ou interpréter des chiffres de satisfaction.
  Se déclenche sur : NPS, CSAT, KPI, indicateur, dashboard, tableau de bord, vue,
  agrégat, taux de réponse, taux de consentement, campagne, heatmap, sparkline,
  graphique, chart, BI, analytics, pilotage.
---

# BI / Pilotage satisfaction ANSET

Le dashboard (`satisfaction_anset.html`, onglet Satisfaction) lit des **vues Supabase
pré-agrégées** — ne jamais recalculer les agrégats côté client, ni requêter la table
brute pour un KPI qui existe déjà en vue.

## Vues de pilotage (migration `20260723090500_reponses_dashboard.sql`)

| Vue | Grain | Sert à |
|-----|-------|--------|
| `v_satisfaction_reseau` | par campagne | KPIs réseau, tendance NPS |
| `v_satisfaction_zone` | campagne × zone | heatmap / comparaison zones |
| `v_satisfaction_conseiller` | campagne × conseiller | classement conseillers |
| `v_taux_reponse` | campagne × agence | suivi diffusion vs réponses |
| `v_satisfaction_motif` | campagne × motif | bloc « par motif » + carte Sinistres |
| `v_reseaux_sociaux` | par campagne | tuile KPI « Réseaux sociaux » (taux_suivi / taux_interet) |
| `v_verbatims` | 1 ligne/commentaire | verbatims (flag `detracteur`, expose `motif`) |

**Motif** (6 slugs : `souscription, sinistre, gestion, reclamation, information, autre`). La carte
« Sinistres clos » lit `v_satisfaction_motif` filtré sur `motif='sinistre'` : `score_nps`,
`csat_sinistre` (gestion, /5) et `delai_indemnisation` (/5). Ces deux dernières ne sont peuplées que
pour les réponses de motif sinistre. Le bloc motif est **niveau réseau** (pas ventilé par agence/zone).

Toutes en `security_invoker = on` → soumises à la RLS `authenticated` (voir skill
**anset-satisfaction**). Nouvelle vue de pilotage : **toujours** `security_invoker = on`
+ `grant select ... to authenticated`, et rester **idempotent** (`create or replace`).

## Formules (canoniques — réutiliser, ne pas réinventer)

- **Segments NPS** sur `nps` (0–10) : promoteur `>= 9`, passif `7–8`, détracteur `<= 6`.
- **Score NPS** = `round(100.0*(promoteurs - detracteurs)/nps_rep, 1)` — dénominateur =
  nombre de réponses **ayant une note NPS** (`count(nps)`), pas le total de réponses.
- **CSAT** : moyennes de `satisfaction_globale`, `note_conseiller`, `note_accueil`
  (échelles laissées telles quelles, arrondi 2 décimales).
- **Taux de réponse** = `100*reponses/envoyes` (envois `statut_envoi='envoye'`).
- **Taux de consentement** = `100*consentements/reponses`.
- **Satisfaction globale en %** = `(csat_global − 1) / 4 × 100` (helper `csatPct`) : 1/5 → 0 %,
  5/5 → 100 %. Surtout **pas** `moyenne/5*100`, qui plancherait à 20 %. Le statut et la couleur
  de la tuile restent calés sur la note /5 via `stCsat` (3 et 4 ⇔ 50 % et 75 %).
- **Cible réseau** : score NPS = **18** — constante JS **`CIBLE_NPS`** (`satisfaction_anset.html`),
  source unique dont dépendent le repère de la jauge, les libellés, la ligne pointillée du graphe
  de tendance, `scoreColor` et `stScore`. Changer la cible = changer cette seule ligne.
  Ne pas confondre avec l'objectif de **délai d'indemnisation**, qui vaut 30 **jours** (`stDelai`).

## Seuils de couleur (helpers JS de l'app)

Toujours colorer un indicateur via ces fonctions, pas au jugé :

- `scoreColor(v)` : `<0` corail · `< CIBLE_NPS` moutarde · `≥ CIBLE_NPS` menthe (3 paliers,
  alignés sur la cible : atteindre l'objectif fait passer l'indicateur au vert).
- `csatColor(v)`  : `<3` corail · `<4` moutarde · `≥4` menthe.
- `tauxColor(v)`  : `<10` corail · `<15` moutarde · `≥15` menthe.
- `null` → `var(--muted)` (jamais un « 0 » trompeur pour une donnée absente ; afficher `—`).

## Graphiques

Rendu **SVG inline maison** (pas de lib de charting). Helpers déjà présents :
`sparkline(vals, {color})`, `lineChartNPS(series)`, heatmap zone en `.hbar`.
Palette `PAL = {blue, ciel, corail, moutarde, menthe, mauve}`. Pour un nouveau
graphique, réutiliser ces primitives et la palette ; charger le skill global
**dataviz** pour la méthode (choix de forme, accessibilité, légendes).

## Conventions

- **Campagne** = chaîne `YYYY-MM` (ex. `2026-07`) ; trier lexicographiquement = trier
  chronologiquement. Les libellés d'axe tronquent l'année (`slice(2)`).
- Formatage : `fmt(v,d)` (décimales, `—` si null), `pct(v)` (entier + %),
  `.num` pour l'alignement tabulaire.
- **Delta** = campagne courante vs précédente ; flèche colorée up/down/flat.
- Ne jamais exposer de PII dans un agrégat destiné à une vue « réseau » — les verbatims
  et données nominatives restent derrière login (RLS).
