-- =====================================================================
--  Table profils — comptes d'accès à l'app de pilotage et leurs rôles.
--  Une ligne par utilisateur auth.users. Alimentée UNIQUEMENT par
--  l'Edge Function `admin-utilisateurs` (service_role), jamais par le
--  navigateur : créer un compte suppose l'API admin de Supabase.
--
--  Rôles :
--    super_admin — gère les comptes (créer, changer de rôle, désactiver)
--    manager     — accès dashboard, prospection, imports et diffusion
--
--  Idempotent : rejouable via `supabase db push`.
-- =====================================================================

create table if not exists public.profils (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  nom         text,
  role        text not null default 'manager' check (role in ('super_admin','manager')),
  actif       boolean not null default true,
  created_at  timestamptz not null default now()
);

create index if not exists idx_profils_role on public.profils (role);

alter table public.profils enable row level security;

-- Lecture ouverte aux comptes connectés : l'app doit connaître son propre rôle
-- (pour afficher ou non l'onglet Utilisateurs) et afficher l'annuaire interne.
-- Aucune donnée client ici, uniquement des comptes ANSET.
drop policy if exists auth_select_profils on public.profils;
create policy auth_select_profils on public.profils
  for select to authenticated using (true);

-- Pas de policy d'écriture : toute modification passe par l'Edge Function en
-- service_role, qui vérifie que l'appelant est super_admin. Un manager ne peut
-- donc pas se promouvoir en modifiant sa propre ligne.

-- --- Amorçage : les comptes déjà existants deviennent des profils, et
-- thomas@anset.pf est le super admin initial.
insert into public.profils (user_id, email, nom, role)
select u.id, u.email,
       initcap(split_part(split_part(u.email, '@', 1), '.', 1)),
       case when u.email = 'thomas@anset.pf' then 'super_admin' else 'manager' end
from auth.users u
where u.email is not null
on conflict (user_id) do nothing;

update public.profils set role = 'super_admin' where email = 'thomas@anset.pf';
