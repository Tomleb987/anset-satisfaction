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
| `v_taux_reponse` | campagne × agence (de l'envoi) | suivi diffusion vs réponses |
| `v_envoi_reference` | 1 ligne/`req` | envoi de référence (le plus récent réellement parti) |
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
  **Attribution (corrigé le 29/07/2026)** : le ratio se calcule sur l'agence/zone de
  l'**ENVOI** des deux côtés — le dénominateur vient du fichier, le numérateur doit donc en venir
  aussi, sinon une agence absente de la liste du formulaire (Site WEB, Polynésie Assurances,
  Commerciaux) reste figée à 0 % et une autre peut dépasser 100 %. La **satisfaction** par agence,
  elle, s'agrège sur l'agence **effective** = `coalesce(déclarée par le client, celle de l'envoi)`.
  Les deux nombres d'une même ligne peuvent donc différer : c'est voulu.
- **Rattachement d'une réponse à sa campagne** : via `v_envoi_reference` (`distinct on (req)`,
  envoi réellement parti le plus récent). Un même `req` peut exister dans plusieurs campagnes ;
  sans ce tri, les réponses se classaient dans une campagne qui n'avait rien envoyé. Même règle
  dans `submit-sondage` — les deux doivent rester alignées.
- **Seuils de volume** : constante **`VOL = {conclure:10, tendance:30, significatif:100}`**
  (`satisfaction_anset.html`), source unique au même titre que `CIBLE_NPS`. `MIN_FIABLE` reste
  comme alias de `VOL.conclure`. Voir « Performance ≠ fiabilité » ci-dessous : le score reste
  toujours affiché, jamais masqué — une réponse fait basculer un NPS de −100 à +100.
- `v_satisfaction_reseau` part de l'**union** réponses ∪ envois : une campagne diffusée sans
  réponse doit apparaître (taux 0 %), sinon elle est absente jusqu'au sélecteur de campagne.
- **Taux de consentement** = `100*consentements/reponses`.
- **Satisfaction globale en %** = `(csat_global − 1) / 4 × 100` (helper `csatPct`) : 1/5 → 0 %,
  5/5 → 100 %. Surtout **pas** `moyenne/5*100`, qui plancherait à 20 %. Le statut et la couleur
  de la tuile restent calés sur la note /5 via `stCsat` (3 et 4 ⇔ 50 % et 75 %).
- **Cible réseau** : score NPS = **18** — constante JS **`CIBLE_NPS`** (`satisfaction_anset.html`),
  source unique dont dépendent le repère de la jauge, les libellés, la ligne pointillée du graphe
  de tendance, `scoreColor` et `stScore`. Changer la cible = changer cette seule ligne.
  Ne pas confondre avec l'objectif de **délai d'indemnisation**, qui vaut 30 **jours** (`stDelai`).

## Performance ≠ fiabilité (règle transverse, à respecter pour tout nouvel indicateur)

Un badge unique répond à « comment est le score ? » en laissant croire qu'il répond à « que vaut
ce score ? ». Sur 3 notes, « À redresser » énonce sur un conseiller une conclusion que la donnée
ne porte pas. Deux dimensions, donc, jamais une seule — helpers de l'app :

- `performance(score, nNps)` : le verdict `stScore` **au-dessus** de `VOL.conclure` ; en dessous,
  « Tendance favorable / neutre / défavorable » en neutre.
- `fiabilite(nNps, taux)` : « Non mesurable / Insuffisante / À confirmer / Limitée / Correcte /
  Bonne », avec un `pourquoi` chiffré pour l'infobulle. Le volume de notes commande d'abord, la
  participation seulement ensuite (sous 10 notes, parler de représentativité est prématuré).
- `classable(nNps)` : autorise un **rang**. Un périmètre non classable sort du classement (tableau
  et barres) au lieu d'en occuper la tête, et n'est pas trié par score mais par volume.
- `stVol(st, pill, nBase)` : même règle pour une note /5 ou un taux — sous le seuil, pastille
  « Provisoire » et couleur retirée. À utiliser pour **toute** nouvelle tuile de verdict.
- `attendu(envoyes, campagne)` → `{rep, notes, taux}` : ce que la campagne peut rendre, au taux de
  participation du **réseau** sur cette même campagne (comparaison à durée écoulée égale). Répond
  à la question que « Non classé » laisse ouverte — le périmètre peut-il l'être ? Deux nombres car
  deux populations : les réponses, et les **notes** (× `nps_rep/reponses` du réseau). Le seuil se
  compare aux notes, jamais aux réponses. Le drapeau « plafond » (seuil hors d'atteinte) ne
  s'affiche que sur un périmètre **pas encore classé** : l'attendu est une prévision au taux du
  réseau, et un périmètre qui la dépasse l'a déjà démentie. Invitations par périmètre : `envoyes`
  dans `v_satisfaction_reseau` / `_zone` / `_conseiller`, et via `v_taux_reponse` pour l'agence
  (la vue agence s'agrège sur l'agence **déclarée** et n'en a pas).
- `ecartSur(nA, nB)` → `deltaTag(..., {fiable})` : un écart n'est un jugement que si les **deux**
  campagnes concluent, sinon il mesure l'écoulement du temps. `{entier:true}` sur les grandeurs
  affichées arrondies (NPS) : l'écart doit être celui des chiffres lus à l'écran.

Ce que la règle interdit en pratique : colorer un score de 72 px sur 1 note, afficher « 100 % de
détracteurs » là où « 1 détracteur sur 1 note » est fidèle (barre **et** légende passent au
nombre), classer une agence à +100 sur une note au-dessus d'une agence à +40 sur soixante, relier
d'un trait plein une campagne pleine à une campagne d'un jour (trait pointillé, point creux,
mention sous le graphe). **Exception assumée** : le taux de réponse garde son verdict à faible
volume — son dénominateur est le nombre d'invitations, `0,2 %` sur 1 240 envois est une mesure.

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
- **Delta** = campagne courante vs précédente ; flèche colorée up/down/flat, neutralisée par
  `{fiable:false}` quand le volume ne permet pas de conclure (cf. « Performance ≠ fiabilité »).
- Ne jamais exposer de PII dans un agrégat destiné à une vue « réseau » — les verbatims
  et données nominatives restent derrière login (RLS).
