-- =============================================================================
--  ANSET — L'espace Administration (imports + diffusion) devient réservé au
--  super admin. Masquer l'onglet ne suffit pas : les imports écrivent
--  directement dans `envois_sondage` / `conseillers` via PostgREST, et les
--  policies « authenticated » laissaient donc n'importe quel manager importer
--  un fichier ou créer des conseillers depuis la console du navigateur.
--
--  Lecture inchangée (les vues du dashboard s'appuient sur ces tables) ;
--  seules les ÉCRITURES passent sous condition de rôle.
--  Les écritures serveur (Edge Functions en service_role) bypassent la RLS.
--  Idempotent.
-- =============================================================================

-- Rôle de l'appelant. `security definer` : la fonction lit `profils` sans
-- dépendre des policies de cette table, ce qui évite tout risque de récursion
-- si elles évoluent. Elle ne renvoie qu'un booléen sur l'appelant lui-même.
create or replace function public.est_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profils p
    where p.user_id = auth.uid() and p.role = 'super_admin' and p.actif
  );
$$;

revoke all on function public.est_super_admin() from public;
grant execute on function public.est_super_admin() to authenticated;

-- --- envois_sondage : import réservé au super admin ------------------------
drop policy if exists auth_insert_envois on public.envois_sondage;
drop policy if exists admin_insert_envois on public.envois_sondage;
create policy admin_insert_envois on public.envois_sondage
  for insert to authenticated with check (public.est_super_admin());

drop policy if exists auth_update_envois on public.envois_sondage;
drop policy if exists admin_update_envois on public.envois_sondage;
create policy admin_update_envois on public.envois_sondage
  for update to authenticated using (public.est_super_admin()) with check (public.est_super_admin());

-- --- conseillers : créés/mis à jour par l'import requête -------------------
drop policy if exists auth_insert_conseillers on public.conseillers;
drop policy if exists admin_insert_conseillers on public.conseillers;
create policy admin_insert_conseillers on public.conseillers
  for insert to authenticated with check (public.est_super_admin());

drop policy if exists auth_update_conseillers on public.conseillers;
drop policy if exists admin_update_conseillers on public.conseillers;
create policy admin_update_conseillers on public.conseillers
  for update to authenticated using (public.est_super_admin()) with check (public.est_super_admin());
