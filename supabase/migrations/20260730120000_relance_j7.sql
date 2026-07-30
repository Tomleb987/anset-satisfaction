-- =============================================================================
--  ANSET — Relance à J+7 des clients qui n'ont pas répondu.
--
--  Une seule relance par invitation, jamais deux : la garantie tient à la colonne
--  `date_relance`. Tant qu'elle est nulle la ligne est relançable, dès qu'elle est
--  posée elle sort définitivement de la file — même si la relance échoue ensuite
--  (l'Edge Function la remet alors à null explicitement).
--
--  POURQUOI PAS UN STATUT `relance` DANS L'ENUM : `statut_envoi = 'envoye'` est la
--  base du taux de réponse (`v_taux_reponse`) et de la progression de diffusion.
--  Un troisième statut ferait sortir les relancés du dénominateur et ferait bondir
--  le taux de réponse sans qu'une seule réponse de plus soit arrivée.
--
--  « N'a pas répondu » se mesure par rapport à CETTE invitation, pas dans l'absolu :
--  un même `req` apparaît dans plusieurs campagnes (constat du 29/07, ~3 800 doublons),
--  donc une réponse antérieure à `date_envoi` ne prouve rien sur l'invitation en
--  cours. D'où la comparaison `date_reponse >= date_envoi`.
--
--  Idempotent.
-- =============================================================================

alter table public.envois_sondage
  add column if not exists date_relance timestamptz;

comment on column public.envois_sondage.date_relance is
  'Horodatage de l''unique relance J+7. Null = relançable, non-null = déjà relancé (ou en cours de relance : la ligne est réservée avant l''envoi).';

-- Index de la file d'attente : la vue ci-dessous filtre d'abord sur ces colonnes.
create index if not exists idx_envois_relance
  on public.envois_sondage (statut_envoi, date_relance, date_envoi);

-- --- La file des relances ----------------------------------------------------
-- Source unique du délai : changer le J+7 se fait ICI, pas dans l'Edge Function
-- ni dans l'app — sinon les trois divergent et le compteur affiché ne correspond
-- plus à ce qui part réellement.
--
-- `req is not null` est un garde-fou : sans référence, impossible de savoir si la
-- personne a répondu. On préfère ne pas relancer que relancer quelqu'un qui a déjà
-- pris le temps de nous répondre.
create or replace view public.v_relances_a_faire
with (security_invoker = on) as
select e.id, e.req, e.campagne, e.email, e.prenom, e.nom,
       e.agence, e.zone, e.conseiller_id, e.motif, e.date_envoi
  from public.envois_sondage e
 where e.statut_envoi = 'envoye'
   and e.email       is not null
   and e.req         is not null
   and e.date_envoi  is not null
   and e.date_relance is null
   and e.date_envoi <= now() - interval '7 days'
   and not exists (
     select 1 from public.reponses_satisfaction r
      where r.req = e.req
        and r.date_reponse >= e.date_envoi
   );

comment on view public.v_relances_a_faire is
  'Invitations parties il y a au moins 7 jours, restées sans réponse et jamais relancées. Source unique du délai de relance.';

grant select on public.v_relances_a_faire to authenticated;
