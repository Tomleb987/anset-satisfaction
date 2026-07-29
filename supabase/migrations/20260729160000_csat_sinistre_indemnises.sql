-- =============================================================================
--  ANSET — La satisfaction sinistre ne concerne que les GESTIONNAIRES SINISTRE.
--
--  CONSTAT (29/07/2026) : `titaina.pea` affichait une « Sat. sinistre » sans
--  figurer une seule fois comme gestionnaire dans la liste des sinistres clos
--  (elle n'apparaît que comme `Gestionnaire` du fichier quittances). Chaîne :
--    1. invitation de campagne QUITTANCE → envoi `motif = null`,
--       `conseiller_id` = gestionnaire de la quittance ;
--    2. le formulaire demandait le motif du contact ; le client répond
--       « sinistre », donc le bloc sinistre s'affichait ;
--    3. `submit-sondage` conservait `sat_sinistre` sur la foi du motif DÉCLARÉ ;
--    4. les vues faisaient `avg(sat_sinistre)` sur toutes les réponses du
--       conseiller → la note de gestion d'un sinistre atterrissait sur un
--       gestionnaire de quittances.
--
--  RÈGLE RETENUE : `csat_sinistre` et `delai_indemnisation` ne s'agrègent que sur
--  les réponses dont l'ENVOI DE RÉFÉRENCE porte `motif = 'sinistre'` — c'est-à-dire
--  les clients réellement indemnisés, invités depuis la liste des sinistres clos,
--  et donc les seuls conseillers qui ont réellement géré un sinistre. Le motif
--  déclaré par le client reste utilisé pour la répartition par motif et les
--  verbatims : il dit pourquoi il a appelé, pas qui a traité son dossier.
--
--  Même prédicat côté `submit-sondage` (les deux mesures ne sont plus écrites
--  hors campagne sinistre) et côté `sondage.html` (les deux questions ne sont
--  plus posées hors lien typé sinistre) : ni la fonction ni les vues ne doivent
--  pouvoir diverger sur cette population.
--
--  Les réponses déjà collectées à tort ne sont PAS effacées (ce sont des réponses
--  de clients) : les vues les excluent, elles restent visibles dans
--  `reponses_satisfaction` et `v_verbatims`.
--
--  `create or replace` partout : les colonnes existantes gardent leur nom, leur
--  type et leur ordre ; les nouvelles (`n_sinistre`, et le volet réponses de
--  `v_sinistres_reseau`) sont ajoutées EN FIN de vue. Idempotent.
-- =============================================================================

-- --- RÉSEAU SINISTRES : envois clos + réponses des indemnisés ----------------
-- La carte « Gestion des sinistres · clients récemment indemnisés » lisait son
-- NPS dans `v_satisfaction_motif` (motif déclaré) et son délai réel ici : deux
-- populations dans une même carte. Tout le volet sinistre vient désormais de
-- cette vue, sur la seule population des indemnisés.
-- La campagne est celle de l'ENVOI des deux côtés (`v_envoi_reference`), sinon le
-- volume de sinistres clos et les réponses ne se comparent pas.
create or replace view public.v_sinistres_reseau
with (security_invoker = on) as
with env as (
  select campagne,
    count(*) filter (where date_ouverture is not null and date_cloture is not null) as n_clos,
    round(avg((date_cloture - date_ouverture))
          filter (where date_ouverture is not null and date_cloture is not null)::numeric, 1) as delai_reel
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
  r.delai_indemnisation
from env e full join rep r using (campagne);

-- --- MOTIF : la répartition reste sur le motif déclaré ------------------------
-- Seules les deux mesures spécifiques sinistre changent de population : elles ne
-- valent que pour les indemnisés. La ligne `motif='sinistre'` peut donc compter
-- 12 réponses et n'avoir qu'une `csat_sinistre` calculée sur 3 d'entre elles —
-- les 9 autres ont déclaré « sinistre » sur une invitation quittance.
create or replace view public.v_satisfaction_motif
with (security_invoker = on) as
with base as (
  select r.*, ref.motif as motif_envoi
    from public.reponses_satisfaction r
    left join public.v_envoi_reference ref on ref.req = r.req
),
rep as (
  select campagne, motif,
    count(*)                                             as reponses,
    count(nps)                                           as nps_rep,
    count(*) filter (where nps >= 9)                     as promoteurs,
    count(*) filter (where nps between 7 and 8)          as passifs,
    count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
    round(avg(nps)::numeric, 2)                          as nps_moyen,
    round(avg(satisfaction_globale)::numeric, 2)         as csat_global,
    round(avg(note_conseiller)::numeric, 2)              as csat_conseiller,
    round((avg(sat_sinistre) filter (where motif_envoi = 'sinistre'))::numeric, 2)        as csat_sinistre,
    round((avg(delai_indemnisation) filter (where motif_envoi = 'sinistre'))::numeric, 2) as delai_indemnisation,
    count(*) filter (where a_consenti_recontact)         as consentements
  from base
  where motif is not null
  group by campagne, motif
)
select campagne, motif, reponses, nps_rep, promoteurs, passifs, detracteurs,
  case when nps_rep > 0 then round(100.0*(promoteurs - detracteurs)/nps_rep, 1) end as score_nps,
  nps_moyen, csat_global, csat_conseiller, csat_sinistre, delai_indemnisation, consentements
from rep;

-- --- AGENCE (satisfaction = agence effective ; sinistre = indemnisés) --------
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
       count(b.sat_sinistre) filter (where b.motif_envoi = 'sinistre') as n_sinistre
  from base b
 group by b.campagne, b.agence_eff;

-- --- ZONE (satisfaction = zone effective, taux = zone d'envoi) --------------
create or replace view public.v_satisfaction_zone
with (security_invoker = on) as
with base as (
  select r.*, ref.motif as motif_envoi
    from public.reponses_satisfaction r
    left join public.v_envoi_reference ref on ref.req = r.req
),
rep as (
  select campagne, zone,
    count(*) as reponses, count(nps) as nps_rep,
    count(*) filter (where nps >= 9) as promoteurs,
    count(*) filter (where nps between 7 and 8) as passifs,
    count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
    round(avg(nps)::numeric, 2) as nps_moyen,
    round(avg(satisfaction_globale)::numeric, 2) as csat_global,
    round(avg(note_conseiller)::numeric, 2) as csat_conseiller,
    round((avg(sat_sinistre) filter (where motif_envoi = 'sinistre'))::numeric, 2) as csat_sinistre,
    count(sat_sinistre) filter (where motif_envoi = 'sinistre') as n_sinistre,
    count(*) filter (where a_consenti_recontact) as consentements
  from base group by campagne, zone
),
env as (
  select campagne, zone, count(*) filter (where statut_envoi = 'envoye') as envoyes
    from public.envois_sondage group by campagne, zone
),
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
  r.csat_sinistre, s.delai_reel,
  r.n_sinistre
from rep r
  left join env e using (campagne, zone)
  left join rep_env re using (campagne, zone)
  left join sin s using (campagne, zone);

-- --- CONSEILLER (le cas titaina.pea) ---------------------------------------
-- `csat_sinistre` / `n_sinistre` ne se remplissent plus que pour un conseiller
-- ayant réellement reçu des réponses d'indemnisés. Un gestionnaire de quittances
-- affiche « — », comme son `delai_reel` (qui, lui, était déjà bon : il ne se
-- calcule que sur les envois `motif='sinistre'`).
create or replace view public.v_satisfaction_conseiller
with (security_invoker = on) as
with base as (
  select r.*, ref.motif as motif_envoi
    from public.reponses_satisfaction r
    left join public.v_envoi_reference ref on ref.req = r.req
),
rep as (
  select campagne, conseiller_id,
    count(*) as reponses, count(nps) as nps_rep,
    count(*) filter (where nps >= 9) as promoteurs,
    count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
    round(avg(nps)::numeric, 2) as nps_moyen,
    round(avg(satisfaction_globale)::numeric, 2) as csat_global,
    round(avg(note_conseiller)::numeric, 2) as csat_conseiller,
    round((avg(sat_sinistre) filter (where motif_envoi = 'sinistre'))::numeric, 2) as csat_sinistre,
    count(sat_sinistre) filter (where motif_envoi = 'sinistre') as n_sinistre,
    count(*) filter (where a_consenti_recontact) as consentements
  from base
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
  r.csat_sinistre, s.delai_reel,
  r.n_sinistre
from rep r
left join env e using (campagne, conseiller_id)
left join sin s using (campagne, conseiller_id)
left join public.conseillers c on c.id = r.conseiller_id;

-- --- Droits (rejouables) ----------------------------------------------------
grant select on public.v_sinistres_reseau     to authenticated;
grant select on public.v_satisfaction_motif   to authenticated;
grant select on public.v_satisfaction_agence  to authenticated;
grant select on public.v_satisfaction_zone    to authenticated;
grant select on public.v_satisfaction_conseiller to authenticated;
