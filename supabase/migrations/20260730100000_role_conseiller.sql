-- =============================================================================
--  ANSET — Rôle `conseiller` : l'agent accède à la prospection et à SES
--  résultats de satisfaction, et à rien d'autre.
--
--  IDENTIFIANT — c'est le login déjà présent dans la requête mensuelle (colonne
--  « Gestionnaire », ex. `manon.marrocq`). Ce login EST `conseillers.id`, et
--  c'est la valeur portée par `reponses_satisfaction.conseiller_id` : aucune
--  correspondance à inventer. Le compte auth utilise l'adresse
--  `<login>@anset.pf` (Supabase Auth exige un e-mail), mais le rattachement fait
--  foi via `profils.conseiller_id` — jamais via l'e-mail, qui peut changer.
--
--  CLOISONNEMENT (arbitré avec le métier) :
--   · Prospection — un conseiller voit TOUS les leads, comme un manager : la
--     file des leads non attribués doit rester prenable par n'importe qui.
--     Rien à changer côté RLS, les policies `leads` / `lead_notes` conviennent.
--   · Satisfaction — il ne voit QUE les réponses qui lui sont attribuées. Ce
--     n'est pas un masquage d'écran : la RLS de `reponses_satisfaction` et
--     `envois_sondage` filtre les LIGNES, donc toutes les vues du dashboard
--     (déclarées `security_invoker = on`) se réduisent d'elles-mêmes à son
--     périmètre, y compris pour un appel PostgREST depuis la console.
--   · `v_satisfaction_reseau` passe en `security_invoker = off` : agrégat par
--     campagne, sans PII ni nom de collègue, il sert de repère de comparaison
--     sur l'écran « Mes résultats ». Sans cette exception, la vue « réseau »
--     renverrait au conseiller ses propres chiffres sous une étiquette réseau —
--     pire qu'une absence de repère.
--
--  Idempotent.
-- =============================================================================

-- --- Rôle : troisième valeur admise ----------------------------------------
-- Le check est retrouvé par son CONTENU et non par son nom : un contrôle resté
-- en place sous un autre nom continuerait à refuser 'conseiller', et l'échec ne
-- se verrait qu'au premier compte créé.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.profils'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%role%'
  loop execute format('alter table public.profils drop constraint %I', c.conname); end loop;
end $$;

alter table public.profils add constraint profils_role_check
  check (role in ('super_admin','manager','conseiller'));

-- --- Rattachement au slug de la requête -------------------------------------
-- `on delete set null` et non `restrict` : si un conseiller disparaît de la
-- table, le compte ne doit pas bloquer la suppression — il se retrouve sans
-- périmètre, donc sans aucune réponse visible (échec fermé, cf. policies).
alter table public.profils
  add column if not exists conseiller_id text
    references public.conseillers(id) on delete set null;

comment on column public.profils.conseiller_id is
  'Login de la requête (= conseillers.id, ex. manon.marrocq). Obligatoire pour un compte role=conseiller : c''est lui qui délimite ce que le compte voit.';

create index if not exists idx_profils_conseiller on public.profils (conseiller_id);

-- --- Qui suis-je ? -----------------------------------------------------------
-- `security definer` : ces fonctions lisent `profils` sans dépendre de ses
-- policies (pas de récursion possible) et ne renvoient que l'état de l'appelant.
--
-- Volontairement SANS filtre sur `actif` : un compte désactivé est banni côté
-- auth, mais si un jeton survivait, il doit rester cantonné à son périmètre
-- plutôt que de basculer dans la branche « pas un conseiller » — qui, elle,
-- voit tout. On échoue fermé.
create or replace function public.est_conseiller()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profils p
    where p.user_id = auth.uid() and p.role = 'conseiller'
  );
$$;

create or replace function public.mon_conseiller_id()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.conseiller_id from public.profils p
   where p.user_id = auth.uid() and p.role = 'conseiller';
$$;

revoke all on function public.est_conseiller()    from public;
revoke all on function public.mon_conseiller_id() from public;
grant execute on function public.est_conseiller()    to authenticated;
grant execute on function public.mon_conseiller_id() to authenticated;

-- --- Réponses : un conseiller ne lit que les siennes -------------------------
-- Les appels sont enveloppés dans un `select` : Postgres les évalue alors une
-- seule fois (InitPlan) au lieu d'une fois par ligne — la table est le plus gros
-- volume lu par le dashboard.
-- `conseiller_id = mon_conseiller_id()` est faux si l'un des deux est null : un
-- compte conseiller sans rattachement ne voit rien, et les réponses non
-- attribuées ne fuient pas.
drop policy if exists auth_select_reponses on public.reponses_satisfaction;
create policy auth_select_reponses on public.reponses_satisfaction
  for select to authenticated
  using (
    (select public.est_conseiller()) is not true
    or conseiller_id = (select public.mon_conseiller_id())
  );

-- --- Envois : même périmètre (dénominateur du taux de réponse) ---------------
-- Sans ça, « Taux de réponse » comparerait ses réponses à lui aux envois de tout
-- le réseau : un pourcentage entre deux populations différentes. Accessoirement,
-- `envois_sondage` porte les e-mails clients — un conseiller n'a pas à lire le
-- fichier d'invitation des autres.
drop policy if exists auth_select_envois on public.envois_sondage;
create policy auth_select_envois on public.envois_sondage
  for select to authenticated
  using (
    (select public.est_conseiller()) is not true
    or conseiller_id = (select public.mon_conseiller_id())
  );

-- --- Le réseau reste un repère, pour tout le monde ---------------------------
-- Agrégat par campagne uniquement (compteurs, moyennes, taux) : aucune ligne
-- client, aucun conseiller nommé. La sortir de la RLS de l'appelant est ce qui
-- permet à « Mes résultats » d'afficher « réseau : +12 » à côté du score perso.
-- ATTENTION : un futur `create or replace view v_satisfaction_reseau with
-- (security_invoker = on)` remettrait la vue sous la RLS de l'appelant et
-- afficherait au conseiller ses propres chiffres en guise de réseau. Rejouer
-- cette ligne après toute reprise de la vue.
alter view public.v_satisfaction_reseau set (security_invoker = off);

comment on view public.v_satisfaction_reseau is
  'Agrégat réseau par campagne. security_invoker = off VOLONTAIRE : sert de repère de comparaison aux comptes conseiller, dont la RLS restreint les lignes sources. Ne jamais y ajouter de colonne nominative ni de PII.';
