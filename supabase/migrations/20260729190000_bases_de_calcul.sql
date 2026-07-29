-- =============================================================================
--  ANSET — Exposer les BASES DE CALCUL des indicateurs (nb de notes réelles).
--
--  CONSTAT (audit du 29/07/2026, campagne 2026-06) : sur 48 réponses, seules 32
--  contiennent une note. Les 16 autres viennent de clients qui ont répondu « non »
--  à la première question (`interaction_recente`) : le formulaire ne leur pose
--  alors AUCUNE question — ni NPS, ni satisfaction, ni motif — et n'enregistre que
--  l'agence, le conseiller et le consentement au recontact.
--
--  Conséquence : « réponses » et « nombre de notes » sont deux populations
--  différentes, et le dashboard utilisait la première comme base de la seconde.
--    * le marqueur « échantillon faible » (< 10 notes) ne se déclenchait pas pour
--      « Agence en ligne » (NPS +85,7 sur 7 notes) ni « Papeete » (+33,3 sur 9) ;
--    * la tuile Satisfaction annonçait « 48 réponses » pour une moyenne sur 32.
--
--  Les vues zone / conseiller / réseau exposaient déjà `nps_rep`. On ajoute donc :
--    * `v_satisfaction_agence.nps_rep`  → l'agence était la seule à ne pas l'avoir
--      (elle n'exposait que promoteurs/passifs/détracteurs, à recomposer côté JS).
--    * `v_satisfaction_reseau.csat_rep` → nombre de réponses ayant réellement noté
--      la satisfaction globale, base de la moyenne affichée.
--
--  Colonnes ajoutées EN FIN de vue, `create or replace` : idempotent.
--  Aucune formule existante n'est modifiée — l'audit n'a trouvé aucun écart entre
--  les vues et un recalcul indépendant depuis les tables brutes.
-- =============================================================================

-- --- AGENCE : + nps_rep (nombre de notes NPS) --------------------------------
create or replace view public.v_satisfaction_agence
with (security_invoker = on) as
with base as (
  select rs.*,
         coalesce(nullif(btrim(rs.agence), ''), ref.agence) as agence_eff,
         ref.motif                                          as motif_envoi
    from public.reponses_satisfaction rs
    left join public.v_envoi_reference ref on ref.req = rs.req
),
sin as (
  select campagne, agence, round(avg(date_cloture - date_ouverture), 1) as delai_reel
    from public.envois_sondage
   where motif = 'sinistre' and date_ouverture is not null and date_cloture is not null
   group by campagne, agence
)
select b.campagne,
       b.agence_eff as agence,
       count(*) as reponses,
       count(*) filter (where b.nps >= 9) as promoteurs,
       count(*) filter (where b.nps >= 7 and b.nps <= 8) as passifs,
       count(*) filter (where b.nps <= 6 and b.nps is not null) as detracteurs,
       case when count(b.nps) > 0
            then round(100.0*(count(*) filter (where b.nps >= 9) - count(*) filter (where b.nps <= 6 and b.nps is not null))::numeric / count(b.nps)::numeric, 1) end as nps_score,
       round(avg(b.nps), 2) as nps_moyen,
       round(avg(b.satisfaction_globale), 2) as csat_global,
       round(avg(b.note_conseiller), 2) as csat_conseiller,
       round((avg(b.sat_sinistre) filter (where b.motif_envoi = 'sinistre'))::numeric, 2) as csat_sinistre,
       (select s.delai_reel from sin s where s.campagne = b.campagne and s.agence = b.agence_eff) as delai_reel,
       case when count(b.nps) > 0
            then round(100.0*(count(*) filter (where b.nps >= 9) - count(*) filter (where b.nps <= 6 and b.nps is not null))::numeric / count(b.nps)::numeric, 1) end as score_nps,
       count(b.sat_sinistre) filter (where b.motif_envoi = 'sinistre') as n_sinistre,
       -- Base du score NPS : les réponses SANS note ne doivent pas la gonfler.
       count(b.nps) as nps_rep
  from base b
 group by b.campagne, b.agence_eff;

-- --- RÉSEAU : + csat_rep (base de la moyenne de satisfaction) ----------------
create or replace view public.v_satisfaction_reseau
with (security_invoker = on) as
with rep as (
  select campagne,
    count(*)                                             as reponses,
    count(nps)                                           as nps_rep,
    count(*) filter (where nps >= 9)                     as promoteurs,
    count(*) filter (where nps between 7 and 8)          as passifs,
    count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
    round(avg(nps)::numeric, 2)                          as nps_moyen,
    round(avg(satisfaction_globale)::numeric, 2)         as csat_global,
    round(avg(note_conseiller)::numeric, 2)              as csat_conseiller,
    round(avg(note_accueil)::numeric, 2)                 as csat_accueil,
    count(*) filter (where a_consenti_recontact)         as consentements,
    count(satisfaction_globale)                          as csat_rep
  from public.reponses_satisfaction
  group by campagne
),
env as (
  select campagne, count(*) filter (where statut_envoi = 'envoye') as envoyes
  from public.envois_sondage group by campagne
)
-- Ordre et nullabilité IDENTIQUES à la vue en production (relevés par `db dump`,
-- pas d'après les fichiers de migration) : `csat_rep` est la seule colonne ajoutée,
-- en fin de liste. `envoyes` reste `e.envoyes` non coalescé.
select coalesce(r.campagne, e.campagne)   as campagne,
  coalesce(r.reponses, 0)                 as reponses,
  coalesce(r.nps_rep, 0)                  as nps_rep,
  coalesce(r.promoteurs, 0)               as promoteurs,
  coalesce(r.passifs, 0)                  as passifs,
  coalesce(r.detracteurs, 0)              as detracteurs,
  case when coalesce(r.nps_rep, 0) > 0
       then round(100.0*(r.promoteurs - r.detracteurs)::numeric / r.nps_rep::numeric, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller, r.csat_accueil,
  coalesce(r.consentements, 0)            as consentements,
  e.envoyes,
  case when coalesce(e.envoyes, 0) > 0
       then round(100.0*coalesce(r.reponses, 0)::numeric / e.envoyes::numeric, 1) end as taux_reponse,
  case when coalesce(r.reponses, 0) > 0
       then round(100.0*r.consentements::numeric / r.reponses::numeric, 1) end as taux_consentement,
  coalesce(r.csat_rep, 0)                 as csat_rep
from rep r full join env e using (campagne)
where coalesce(e.envoyes, 0) > 0 or coalesce(r.reponses, 0) > 0;

grant select on public.v_satisfaction_agence to authenticated;
grant select on public.v_satisfaction_reseau to authenticated;
