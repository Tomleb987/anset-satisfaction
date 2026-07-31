-- =============================================================================
--  ANSET — `v_satisfaction_conseiller` part de l'UNION envois ∪ réponses.
--
--  CONSTAT : la vue partait de `rep` (les réponses) et rattachait les envois en
--  `left join`. Un conseiller dont AUCUN client n'a répondu était donc absent de
--  la vue — pas « à zéro », absent : ni ligne dans le détail par conseiller, ni
--  dénominateur, ni attendu. Or c'est exactement la population qu'il faut voir :
--  celle dont on ne sait pas si le silence vient d'un envoi manqué, d'un fichier
--  sans e-mails, ou d'une participation simplement trop faible.
--
--  Même correctif que `v_satisfaction_reseau` (migration 20260723090500), pour la
--  même raison : « une campagne diffusée sans réponse doit apparaître (taux 0 %),
--  sinon elle est absente jusqu'au sélecteur de campagne ».
--
--  Ce que la vue rend désormais pour un conseiller invité mais sans retour :
--  `reponses = 0`, `nps_rep = 0`, `envoyes = N`, `taux_reponse = 0.0`, et toutes
--  les moyennes à NULL (pas à 0 — une note absente n'est pas une note nulle).
--
--  `create or replace` : mêmes colonnes, mêmes types, même ordre — les droits et
--  la RLS (`security_invoker = on`) sont conservés. Idempotent.
-- =============================================================================

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
  -- `having` : on ne fabrique pas de ligne pour un conseiller dont rien n'est
  -- réellement parti (fichier importé mais envoi en échec ou encore en attente).
  -- Sans retour ATTENDU, il n'y a rien à lire — seulement une ligne de bruit.
  select campagne, conseiller_id, count(*) filter (where statut_envoi = 'envoye') as envoyes
  from public.envois_sondage where conseiller_id is not null
  group by campagne, conseiller_id
  having count(*) filter (where statut_envoi = 'envoye') > 0
),
sin as (
  select campagne, conseiller_id, round(avg((date_cloture - date_ouverture))::numeric, 1) as delai_reel
  from public.envois_sondage
  where motif='sinistre' and conseiller_id is not null and date_ouverture is not null and date_cloture is not null
  group by campagne, conseiller_id
)
-- `full join ... using` : les colonnes de jointure sortent déjà fusionnées
-- (`coalesce` implicite), c'est ce qui permet aux jointures suivantes de s'y
-- accrocher sans répéter le coalesce.
select campagne, conseiller_id,
  c.nom as conseiller_nom, c.agence,
  coalesce(r.reponses, 0)    as reponses,
  coalesce(r.nps_rep, 0)     as nps_rep,
  coalesce(r.promoteurs, 0)  as promoteurs,
  coalesce(r.detracteurs, 0) as detracteurs,
  case when coalesce(r.nps_rep, 0) > 0
       then round(100.0*(r.promoteurs - r.detracteurs)/r.nps_rep, 1) end as score_nps,
  r.nps_moyen, r.csat_global, r.csat_conseiller,
  coalesce(r.consentements, 0) as consentements,
  e.envoyes,
  -- Un conseiller invité sans retour affiche 0,0 % — un taux réel, pas un NULL :
  -- « — » laisserait croire que le dénominateur manque alors qu'il est connu.
  case when coalesce(e.envoyes, 0) > 0
       then round(100.0*coalesce(r.reponses, 0)/e.envoyes, 1) end as taux_reponse,
  r.csat_sinistre, s.delai_reel,
  coalesce(r.n_sinistre, 0) as n_sinistre
from rep r
full join env e using (campagne, conseiller_id)
left join sin s using (campagne, conseiller_id)
left join public.conseillers c on c.id = coalesce(r.conseiller_id, e.conseiller_id);

comment on view public.v_satisfaction_conseiller is
  'Indicateurs par conseiller et par campagne, sur l''UNION envois ∪ réponses : un conseiller invité dont personne n''a répondu apparaît avec reponses = 0 et son nombre d''invitations, au lieu d''être absent. security_invoker = on : la RLS de l''appelant s''applique (un conseiller ne voit que sa ligne).';

grant select on public.v_satisfaction_conseiller to authenticated;

