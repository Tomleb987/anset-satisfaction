-- =============================================================================
-- ANSET — Délai réel d'indemnisation (clôture − ouverture) + satisfaction
-- sinistre déclinée par entité.
--   * envois_sondage : date_ouverture / date_cloture (issues du fichier sinistres).
--   * v_sinistres_reseau : délai réel moyen + nb de sinistres clos par campagne.
--   * v_satisfaction_agence / zone / conseiller : + csat_sinistre + delai_reel.
-- Colonnes AJOUTÉES en fin de vue (compatibles create-or-replace). Idempotent.
-- =============================================================================

alter table public.envois_sondage add column if not exists date_ouverture date;
alter table public.envois_sondage add column if not exists date_cloture   date;

-- --- Vue RÉSEAU sinistres (délai réel) --------------------------------------
create or replace view public.v_sinistres_reseau
with (security_invoker = on) as
select campagne,
  count(*) filter (where date_ouverture is not null and date_cloture is not null) as n_clos,
  round(avg((date_cloture - date_ouverture))
        filter (where date_ouverture is not null and date_cloture is not null)::numeric, 1) as delai_reel
from public.envois_sondage
where motif = 'sinistre'
group by campagne;

-- --- Vue AGENCE (+ csat_sinistre, delai_reel) -------------------------------
create or replace view public.v_satisfaction_agence
with (security_invoker = on) as
with sin as (
  select campagne, agence,
    round(avg((date_cloture - date_ouverture))::numeric, 1) as delai_reel
  from public.envois_sondage
  where motif='sinistre' and date_ouverture is not null and date_cloture is not null
  group by campagne, agence
)
select campagne, agence,
  count(*)                                             as reponses,
  count(*) filter (where nps >= 9)                     as promoteurs,
  count(*) filter (where nps between 7 and 8)          as passifs,
  count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
  case when count(nps) > 0 then round(100.0*(
        count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6 and nps is not null)
      )/count(nps), 1) end                             as nps_score,
  round(avg(nps)::numeric, 2)                          as nps_moyen,
  round(avg(satisfaction_globale)::numeric, 2)         as csat_global,
  round(avg(note_conseiller)::numeric, 2)              as csat_conseiller,
  round(avg(sat_sinistre)::numeric, 2)                 as csat_sinistre,
  (select s.delai_reel from sin s where s.campagne = rs.campagne and s.agence = rs.agence) as delai_reel
from public.reponses_satisfaction rs
group by campagne, agence;

-- --- Vue ZONE (+ csat_sinistre, delai_reel) ---------------------------------
create or replace view public.v_satisfaction_zone
with (security_invoker = on) as
with rep as (
  select campagne, zone,
    count(*) as reponses, count(nps) as nps_rep,
    count(*) filter (where nps >= 9) as promoteurs,
    count(*) filter (where nps between 7 and 8) as passifs,
    count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
    round(avg(nps)::numeric, 2) as nps_moyen,
    round(avg(satisfaction_globale)::numeric, 2) as csat_global,
    round(avg(note_conseiller)::numeric, 2) as csat_conseiller,
    round(avg(sat_sinistre)::numeric, 2) as csat_sinistre,
    count(*) filter (where a_consenti_recontact) as consentements
  from public.reponses_satisfaction group by campagne, zone
),
env as (
  select campagne, zone, count(*) filter (where statut_envoi = 'envoye') as envoyes
  from public.envois_sondage group by campagne, zone
),
sin as (
  select campagne, zone, round(avg((date_cloture - date_ouverture))::numeric, 1) as delai_reel
  from public.envois_sondage
  where motif='sinistre' and date_ouverture is not null and date_cloture is not null
  group by campagne, zone
)
select r.campagne, r.zone, r.reponses, r.nps_rep, r.promoteurs, r.passifs, r.detracteurs,
  case when r.nps_rep > 0 then round(100.0*(r.promoteurs - r.detracteurs)/r.nps_rep, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller, r.consentements,
  e.envoyes,
  case when coalesce(e.envoyes,0) > 0 then round(100.0*r.reponses/e.envoyes, 1) end as taux_reponse,
  r.csat_sinistre, s.delai_reel
from rep r
left join env e using (campagne, zone)
left join sin s using (campagne, zone);

-- --- Vue CONSEILLER (+ csat_sinistre, delai_reel) ---------------------------
create or replace view public.v_satisfaction_conseiller
with (security_invoker = on) as
with rep as (
  select campagne, conseiller_id,
    count(*) as reponses, count(nps) as nps_rep,
    count(*) filter (where nps >= 9) as promoteurs,
    count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
    round(avg(nps)::numeric, 2) as nps_moyen,
    round(avg(satisfaction_globale)::numeric, 2) as csat_global,
    round(avg(note_conseiller)::numeric, 2) as csat_conseiller,
    round(avg(sat_sinistre)::numeric, 2) as csat_sinistre,
    count(*) filter (where a_consenti_recontact) as consentements
  from public.reponses_satisfaction
  where conseiller_id is not null
  group by campagne, conseiller_id
),
env as (
  select campagne, conseiller_id, count(*) filter (where statut_envoi = 'envoye') as envoyes
  from public.envois_sondage where conseiller_id is not null group by campagne, conseiller_id
),
sin as (
  select campagne, conseiller_id, round(avg((date_cloture - date_ouverture))::numeric, 1) as delai_reel
  from public.envois_sondage
  where motif='sinistre' and conseiller_id is not null and date_ouverture is not null and date_cloture is not null
  group by campagne, conseiller_id
)
select r.campagne, r.conseiller_id, c.nom as conseiller_nom, c.agence,
  r.reponses, r.nps_rep, r.promoteurs, r.detracteurs,
  case when r.nps_rep > 0 then round(100.0*(r.promoteurs - r.detracteurs)/r.nps_rep, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller, r.consentements,
  e.envoyes,
  case when coalesce(e.envoyes,0) > 0 then round(100.0*r.reponses/e.envoyes, 1) end as taux_reponse,
  r.csat_sinistre, s.delai_reel
from rep r
left join env e using (campagne, conseiller_id)
left join sin s using (campagne, conseiller_id)
left join public.conseillers c on c.id = r.conseiller_id;

grant select on public.v_sinistres_reseau to authenticated;
