-- =============================================================================
-- ANSET — Motif d'interaction + volet Sinistres clos.
--  * reponses_satisfaction : motif + 2 mesures spécifiques sinistre.
--  * envois_sondage        : motif (renseigné 'sinistre' à l'import des sinistres
--                            clos ; null pour la requête générale → le client choisit).
--  * v_satisfaction_motif  : pilotage par motif (dont la carte Sinistres).
--  * v_verbatims           : expose le motif + les mesures sinistre.
-- Additif, idempotent.
-- =============================================================================

-- --- reponses_satisfaction : attribution du motif + mesures sinistre ---------
alter table public.reponses_satisfaction add column if not exists motif                text;
alter table public.reponses_satisfaction add column if not exists sat_sinistre         smallint;
alter table public.reponses_satisfaction add column if not exists delai_indemnisation  smallint;

create index if not exists idx_rs_motif on public.reponses_satisfaction (motif);

-- --- envois_sondage : motif de la campagne (typée) ---------------------------
alter table public.envois_sondage add column if not exists motif text;
create index if not exists idx_envois_motif on public.envois_sondage (motif);

-- --- Vue MOTIF (par campagne × motif) ---------------------------------------
-- Réponse-seulement : le motif est choisi par le client (requête générale) ou
-- imposé par la campagne (sinistre) ; pas de taux de réponse ici (voir v_taux_reponse).
create or replace view public.v_satisfaction_motif
with (security_invoker = on) as
with rep as (
  select campagne, motif,
    count(*)                                             as reponses,
    count(nps)                                           as nps_rep,
    count(*) filter (where nps >= 9)                     as promoteurs,
    count(*) filter (where nps between 7 and 8)          as passifs,
    count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
    round(avg(nps)::numeric, 2)                          as nps_moyen,
    round(avg(satisfaction_globale)::numeric, 2)         as csat_global,
    round(avg(note_conseiller)::numeric, 2)              as csat_conseiller,
    round(avg(sat_sinistre)::numeric, 2)                 as csat_sinistre,
    round(avg(delai_indemnisation)::numeric, 2)          as delai_indemnisation,
    count(*) filter (where a_consenti_recontact)         as consentements
  from public.reponses_satisfaction
  where motif is not null
  group by campagne, motif
)
select campagne, motif, reponses, nps_rep, promoteurs, passifs, detracteurs,
  case when nps_rep > 0 then round(100.0*(promoteurs - detracteurs)/nps_rep, 1) end as score_nps,
  nps_moyen, csat_global, csat_conseiller, csat_sinistre, delai_indemnisation, consentements
from rep;

-- --- v_verbatims : ajouter motif + mesures sinistre --------------------------
create or replace view public.v_verbatims
with (security_invoker = on) as
select response_id, date_reponse, campagne, agence, zone, conseiller_id, motif,
  nps, nps_categorie, satisfaction_globale, note_conseiller, sat_sinistre, delai_indemnisation, commentaire,
  (coalesce(nps, 10) <= 6 or coalesce(satisfaction_globale, 5) <= 3) as detracteur
from public.reponses_satisfaction
where commentaire is not null and length(btrim(commentaire)) > 0;

-- --- Droits -----------------------------------------------------------------
grant select on public.v_satisfaction_motif to authenticated;
