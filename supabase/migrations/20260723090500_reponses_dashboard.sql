-- =============================================================================
-- ANSET — Attribution des réponses + vues de pilotage (dashboard satisfaction)
-- Ajoute req / conseiller_id / zone à reponses_satisfaction (déjà envoyés par le
-- formulaire via le lien personnalisé, mais non stockés jusqu'ici) et crée les
-- vues agrégées réseau / zone / conseiller / taux de réponse / verbatims.
-- Idempotent.
-- =============================================================================

-- --- Colonnes d'attribution sur reponses_satisfaction ----------------------
-- conseiller_id : PAS de FK (on ne veut JAMAIS perdre une réponse à cause d'une
-- contrainte ; l'attribution se fait par slug, alignée sur conseillers.id).
alter table public.reponses_satisfaction add column if not exists req           text;
alter table public.reponses_satisfaction add column if not exists conseiller_id text;
alter table public.reponses_satisfaction add column if not exists zone          text;

create index if not exists idx_rs_campagne   on public.reponses_satisfaction (campagne);
create index if not exists idx_rs_agence      on public.reponses_satisfaction (agence);
create index if not exists idx_rs_zone        on public.reponses_satisfaction (zone);
create index if not exists idx_rs_conseiller  on public.reponses_satisfaction (conseiller_id);
create index if not exists idx_rs_req         on public.reponses_satisfaction (req);

-- --- Vue RÉSEAU (par campagne) ---------------------------------------------
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
    count(*) filter (where a_consenti_recontact)         as consentements
  from public.reponses_satisfaction
  group by campagne
),
env as (
  select campagne, count(*) filter (where statut_envoi = 'envoye') as envoyes
  from public.envois_sondage group by campagne
)
select r.campagne, r.reponses, r.nps_rep, r.promoteurs, r.passifs, r.detracteurs,
  case when r.nps_rep > 0 then round(100.0*(r.promoteurs - r.detracteurs)/r.nps_rep, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller, r.csat_accueil, r.consentements,
  e.envoyes,
  case when coalesce(e.envoyes,0) > 0 then round(100.0*r.reponses/e.envoyes, 1) end as taux_reponse,
  case when r.reponses > 0 then round(100.0*r.consentements/r.reponses, 1) end as taux_consentement
from rep r left join env e using (campagne);

-- --- Vue ZONE (par campagne, zone) -----------------------------------------
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
    count(*) filter (where a_consenti_recontact) as consentements
  from public.reponses_satisfaction group by campagne, zone
),
env as (
  select campagne, zone, count(*) filter (where statut_envoi = 'envoye') as envoyes
  from public.envois_sondage group by campagne, zone
)
select r.campagne, r.zone, r.reponses, r.nps_rep, r.promoteurs, r.passifs, r.detracteurs,
  case when r.nps_rep > 0 then round(100.0*(r.promoteurs - r.detracteurs)/r.nps_rep, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller, r.consentements,
  e.envoyes,
  case when coalesce(e.envoyes,0) > 0 then round(100.0*r.reponses/e.envoyes, 1) end as taux_reponse
from rep r left join env e using (campagne, zone);

-- --- Vue CONSEILLER (par campagne, conseiller) -----------------------------
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
    count(*) filter (where a_consenti_recontact) as consentements
  from public.reponses_satisfaction
  where conseiller_id is not null
  group by campagne, conseiller_id
),
env as (
  select campagne, conseiller_id, count(*) filter (where statut_envoi = 'envoye') as envoyes
  from public.envois_sondage where conseiller_id is not null group by campagne, conseiller_id
)
select r.campagne, r.conseiller_id, c.nom as conseiller_nom, c.agence,
  r.reponses, r.nps_rep, r.promoteurs, r.detracteurs,
  case when r.nps_rep > 0 then round(100.0*(r.promoteurs - r.detracteurs)/r.nps_rep, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller, r.consentements,
  e.envoyes,
  case when coalesce(e.envoyes,0) > 0 then round(100.0*r.reponses/e.envoyes, 1) end as taux_reponse
from rep r
left join env e using (campagne, conseiller_id)
left join public.conseillers c on c.id = r.conseiller_id;

-- --- Vue TAUX DE RÉPONSE (par campagne, agence) ----------------------------
create or replace view public.v_taux_reponse
with (security_invoker = on) as
with env as (
  select campagne, agence, count(*) filter (where statut_envoi = 'envoye') as envoyes
  from public.envois_sondage group by campagne, agence
),
rep as (
  select campagne, agence, count(*) as repondants
  from public.reponses_satisfaction group by campagne, agence
)
select coalesce(e.campagne, r.campagne) as campagne,
       coalesce(e.agence, r.agence)      as agence,
       coalesce(e.envoyes, 0)            as envoyes,
       coalesce(r.repondants, 0)         as repondants,
       case when coalesce(e.envoyes,0) > 0 then round(100.0*coalesce(r.repondants,0)/e.envoyes, 1) end as taux_reponse
from env e full join rep r using (campagne, agence);

-- --- Vue VERBATIMS ----------------------------------------------------------
create or replace view public.v_verbatims
with (security_invoker = on) as
select response_id, date_reponse, campagne, agence, zone, conseiller_id,
  nps, nps_categorie, satisfaction_globale, note_conseiller, commentaire,
  (coalesce(nps, 10) <= 6 or coalesce(satisfaction_globale, 5) <= 3) as detracteur
from public.reponses_satisfaction
where commentaire is not null and length(btrim(commentaire)) > 0;

-- --- Droits (RLS appliquée via security_invoker) ---------------------------
grant select on public.v_satisfaction_reseau, public.v_satisfaction_zone,
                public.v_satisfaction_conseiller, public.v_taux_reponse,
                public.v_verbatims
  to authenticated;
