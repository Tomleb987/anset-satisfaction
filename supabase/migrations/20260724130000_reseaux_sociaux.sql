-- =============================================================================
-- ANSET — Question « réseaux sociaux » ajoutée au questionnaire.
--  reponses_satisfaction.reseaux_sociaux : slug parmi {oui, interesse, non}
--  (oui = suit la marque · interesse = pas encore mais intéressé · non).
--  Collectée uniquement dans la branche « interaction = oui ».
-- Additif, idempotent.
-- =============================================================================

alter table public.reponses_satisfaction add column if not exists reseaux_sociaux text;

-- --- Vue RÉSEAUX SOCIAUX (par campagne) -------------------------------------
-- Funnel de suivi de la marque : suit / intéressé / non, + taux dérivés.
create or replace view public.v_reseaux_sociaux
with (security_invoker = on) as
with rep as (
  select campagne,
    count(*) filter (where reseaux_sociaux is not null)          as repondu,
    count(*) filter (where reseaux_sociaux = 'oui')              as suit,
    count(*) filter (where reseaux_sociaux = 'interesse')        as interesses,
    count(*) filter (where reseaux_sociaux = 'non')              as non_suit
  from public.reponses_satisfaction
  group by campagne
)
select campagne, repondu, suit, interesses, non_suit,
  case when repondu > 0 then round(100.0*suit/repondu, 1)       end as taux_suivi,
  case when repondu > 0 then round(100.0*interesses/repondu, 1) end as taux_interet
from rep;

grant select on public.v_reseaux_sociaux to authenticated;
