-- =============================================================================
--  ANSET — Délai de traitement des sinistres : ajouter la MÉDIANE (et le p90).
--
--  CONSTAT (29/07/2026, données réelles campagne 2026-06, 143 sinistres clos) :
--    * moyenne  `delai_reel`   = 328,9 j
--    * médiane  `delai_median` = 102,0 j
--    * p90      `delai_p90`    = 765,8 j
--  Le fichier mélange des dossiers ouverts en 2016-2019 et clos en juin 2026
--  (contentieux, expertises longues) et des dossiers ouverts et clos dans la même
--  semaine. Sur une distribution à queue aussi longue, la moyenne est tirée par une
--  poignée de dossiers et ne décrit aucun client réel : l'écart moyenne/médiane
--  (329 vs 102) est du même ordre que la médiane elle-même.
--  Attention à la lecture : la médiane à 102 j reste TRÈS au-dessus de l'objectif
--  de 30 j — la moyenne exagérait le problème, elle ne l'inventait pas.
--
--  Biais de sélection à garder en tête : la liste ne contient que les sinistres
--  CLOS sur la période. Les dossiers ouverts anciens et toujours ouverts n'y sont
--  pas, et un dossier ouvert récemment n'y figure que s'il a été réglé vite. Ces
--  chiffres décrivent donc les délais de clôture constatés, pas le stock en cours.
--
--  On AJOUTE donc :
--    * `delai_median` → moitié des sinistres clos plus vite, moitié plus lentement.
--                       C'est ce qui devient l'indicateur de pilotage (tuile).
--    * `delai_p90`    → 9 dossiers sur 10 sont clos en moins de X jours ; c'est
--                       lui qui rend la queue longue visible sans écraser le reste.
--  `delai_reel` (la moyenne) est CONSERVÉE : elle reste lue par les vues
--  agence/zone/conseiller et par la colonne « Délai réel » du détail, et retirer
--  une colonne casserait `create or replace`.
--
--  `percentile_cont` interpole entre les deux valeurs encadrantes (médiane d'un
--  nombre pair de dossiers = moyenne des deux du milieu), ce qui est le comportement
--  attendu pour un délai. `filter` restreint aux dossiers réellement clos, comme
--  pour `n_clos` et la moyenne : un sinistre sans date de clôture n'a pas de délai.
--
--  Colonnes ajoutées EN FIN de vue, `create or replace` : idempotent.
-- =============================================================================

create or replace view public.v_sinistres_reseau
with (security_invoker = on) as
with env as (
  select campagne,
    count(*) filter (where date_ouverture is not null and date_cloture is not null) as n_clos,
    round(avg((date_cloture - date_ouverture))
          filter (where date_ouverture is not null and date_cloture is not null)::numeric, 1) as delai_reel,
    round(percentile_cont(0.5) within group (order by (date_cloture - date_ouverture))
          filter (where date_ouverture is not null and date_cloture is not null)::numeric, 1) as delai_median,
    round(percentile_cont(0.9) within group (order by (date_cloture - date_ouverture))
          filter (where date_ouverture is not null and date_cloture is not null)::numeric, 1) as delai_p90
  from public.envois_sondage
  where motif = 'sinistre'
  group by campagne
),
-- Réponses des seuls indemnisés. Une réponse sans `req` (accès direct au
-- formulaire) n'a pas d'envoi de référence : elle est exclue, faute de pouvoir
-- prouver qu'un sinistre a bien été traité.
rep as (
  select ref.campagne                                        as campagne,
    count(*)                                                 as reponses,
    count(r.nps)                                             as nps_rep,
    count(*) filter (where r.nps >= 9)                       as promoteurs,
    count(*) filter (where r.nps <= 6 and r.nps is not null)  as detracteurs,
    round(avg(r.sat_sinistre)::numeric, 2)                   as csat_sinistre,
    round(avg(r.delai_indemnisation)::numeric, 2)            as delai_indemnisation
  from public.reponses_satisfaction r
  join public.v_envoi_reference ref on ref.req = r.req
  where ref.motif = 'sinistre'
  group by ref.campagne
)
select coalesce(e.campagne, r.campagne) as campagne,
  coalesce(e.n_clos, 0)                 as n_clos,
  e.delai_reel,
  coalesce(r.reponses, 0)               as reponses,
  coalesce(r.nps_rep, 0)                as nps_rep,
  coalesce(r.promoteurs, 0)             as promoteurs,
  coalesce(r.detracteurs, 0)            as detracteurs,
  case when coalesce(r.nps_rep, 0) > 0
       then round(100.0*(r.promoteurs - r.detracteurs)::numeric / r.nps_rep::numeric, 1) end as score_nps,
  r.csat_sinistre,
  r.delai_indemnisation,
  e.delai_median,
  e.delai_p90
from env e full join rep r using (campagne);

grant select on public.v_sinistres_reseau to authenticated;
