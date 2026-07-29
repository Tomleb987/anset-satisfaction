-- =============================================================================
--  ANSET — Cohérence de l'attribution agence / zone dans les vues de pilotage.
--
--  CONSTAT (29/07/2026, données réelles) :
--   1. Un même `req` existe dans plusieurs campagnes (le même fichier source
--      importé sur deux mois : 3864 req en double). La réponse était rattachée à
--      une ligne d'envoi arbitraire, donc parfois à une campagne qui n'avait rien
--      envoyé. Corrigé dans `submit-sondage` (tri sur date_envoi) ; ici on donne
--      aux vues la même règle de référence.
--   2. Le taux de réponse par agence comparait deux populations différentes :
--      dénominateur = agence du FICHIER, numérateur = agence CHOISIE par le
--      client. D'où des agences éternellement à 0 % (Site WEB, Polynésie
--      Assurances, Commerciaux : elles ne figurent pas dans la liste du
--      formulaire) et la possibilité d'un taux supérieur à 100 %.
--
--  RÈGLE RETENUE :
--   · satisfaction par agence/zone → agence EFFECTIVE = celle déclarée par le
--     client, à défaut celle de l'envoi (le client sait où il a été servi) ;
--   · taux de réponse → agence/zone de l'ENVOI des deux côtés du ratio, seule
--     façon qu'un pourcentage compare la même population.
--  Idempotent.
-- =============================================================================

-- Ligne d'envoi de référence pour un `req` : celle réellement partie, la plus
-- récente. Même règle que `submit-sondage`, pour que la fonction et les vues ne
-- puissent pas diverger sur l'attribution d'une réponse.
create or replace view public.v_envoi_reference
with (security_invoker = on) as
select distinct on (req)
       req, campagne, agence, zone, conseiller_id, motif, date_envoi
  from public.envois_sondage
 where req is not null and date_envoi is not null
 order by req, date_envoi desc;

grant select on public.v_envoi_reference to authenticated;

-- --- TAUX DE RÉPONSE (campagne × agence de l'envoi) ------------------------
create or replace view public.v_taux_reponse
with (security_invoker = on) as
with env as (
  select campagne, agence, count(*) filter (where statut_envoi = 'envoye') as envoyes
    from public.envois_sondage group by campagne, agence
),
rep as (
  -- Réponse rattachée à l'agence de SON envoi ; à défaut (accès direct au
  -- formulaire, sans req) à ce que le client a déclaré.
  select coalesce(ref.campagne, r.campagne) as campagne,
         coalesce(ref.agence, r.agence)      as agence,
         count(*)                            as repondants
    from public.reponses_satisfaction r
    left join public.v_envoi_reference ref on ref.req = r.req
   group by 1, 2
)
select coalesce(e.campagne, r.campagne) as campagne,
       coalesce(e.agence, r.agence)      as agence,
       coalesce(e.envoyes, 0)            as envoyes,
       coalesce(r.repondants, 0)         as repondants,
       case when coalesce(e.envoyes,0) > 0
            then round(100.0*coalesce(r.repondants,0)/e.envoyes, 1) end as taux_reponse
  from env e full join rep r using (campagne, agence);

-- --- SATISFACTION PAR AGENCE (agence effective) ----------------------------
-- `create or replace` : l'ordre et le type des colonnes existantes sont
-- conservés, `score_nps` est ajouté À LA FIN. Cet alias existe pour aligner le
-- nom sur les autres vues (`nps_score` ici, `score_nps` partout ailleurs) sans
-- casser le code qui lit déjà `nps_score`.
create or replace view public.v_satisfaction_agence
with (security_invoker = on) as
with base as (
  select rs.*,
         coalesce(nullif(btrim(rs.agence), ''), ref.agence) as agence_eff
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
       round(avg(b.sat_sinistre), 2) as csat_sinistre,
       (select s.delai_reel from sin s where s.campagne = b.campagne and s.agence = b.agence_eff) as delai_reel,
       case when count(b.nps) > 0
            then round(100.0*(count(*) filter (where b.nps >= 9) - count(*) filter (where b.nps <= 6 and b.nps is not null))::numeric / count(b.nps)::numeric, 1) end as score_nps
  from base b
 group by b.campagne, b.agence_eff;

-- --- SATISFACTION PAR ZONE (satisfaction = zone effective, taux = zone d'envoi)
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
-- Numérateur du taux : réponses rattachées à la zone de LEUR envoi.
rep_env as (
  select coalesce(ref.campagne, r.campagne) as campagne,
         coalesce(ref.zone, r.zone)          as zone,
         count(*)                            as repondants
    from public.reponses_satisfaction r
    left join public.v_envoi_reference ref on ref.req = r.req
   group by 1, 2
),
sin as (
  select campagne, zone, round(avg(date_cloture - date_ouverture), 1) as delai_reel
    from public.envois_sondage
   where motif = 'sinistre' and date_ouverture is not null and date_cloture is not null
   group by campagne, zone
)
select r.campagne, r.zone, r.reponses, r.nps_rep, r.promoteurs, r.passifs, r.detracteurs,
  case when r.nps_rep > 0 then round(100.0*(r.promoteurs - r.detracteurs)::numeric/r.nps_rep::numeric, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller, r.consentements,
  e.envoyes,
  case when coalesce(e.envoyes,0) > 0
       then round(100.0*coalesce(re.repondants,0)::numeric/e.envoyes::numeric, 1) end as taux_reponse,
  r.csat_sinistre, s.delai_reel
from rep r
  left join env e using (campagne, zone)
  left join rep_env re using (campagne, zone)
  left join sin s using (campagne, zone);

-- --- RÉSEAU : une campagne diffusée doit apparaître même sans réponse --------
-- La vue partait des réponses : une campagne dont les invitations sont parties
-- mais dont personne n'a encore répondu était absente du dashboard (elle ne
-- figurait même pas dans le sélecteur de campagne), donc un taux de réponse de
-- 0 % restait invisible. On part maintenant de l'union des deux côtés, en ne
-- retenant que les campagnes qui ont réellement une activité : au moins un envoi
-- parti, ou au moins une réponse.
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
select coalesce(r.campagne, e.campagne)   as campagne,
  coalesce(r.reponses, 0)                 as reponses,
  coalesce(r.nps_rep, 0)                  as nps_rep,
  coalesce(r.promoteurs, 0)               as promoteurs,
  coalesce(r.passifs, 0)                  as passifs,
  coalesce(r.detracteurs, 0)              as detracteurs,
  case when coalesce(r.nps_rep,0) > 0
       then round(100.0*(r.promoteurs - r.detracteurs)/r.nps_rep, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller, r.csat_accueil,
  coalesce(r.consentements, 0)            as consentements,
  e.envoyes,
  case when coalesce(e.envoyes,0) > 0
       then round(100.0*coalesce(r.reponses,0)/e.envoyes, 1) end as taux_reponse,
  case when coalesce(r.reponses,0) > 0
       then round(100.0*r.consentements/r.reponses, 1) end as taux_consentement
from rep r full join env e using (campagne)
where coalesce(e.envoyes, 0) > 0 or coalesce(r.reponses, 0) > 0;
