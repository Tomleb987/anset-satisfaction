-- =============================================================================
--  ANSET — `profils` : un compte ne lit plus que sa propre ligne.
--
--  CE QUI A CHANGÉ AUTOUR DE CETTE POLICY. `auth_select_profils` était en
--  `using (true)`, justifié à l'époque par « annuaire interne, aucune donnée
--  client » — défendable quand les deux seuls rôles, `manager` et `super_admin`,
--  voyaient de toute façon le réseau entier. L'arrivée du rôle `conseiller`
--  (migration 20260730100000) a rendu cette lecture ouverte incohérente : le
--  cloisonnement filtre ses réponses et ses envois, mais il pouvait encore lire
--  les 60 comptes de l'app — nom, adresse, rôle et rattachement de chaque
--  collègue, et donc repérer nommément qui est super admin. Constaté le
--  30/07/2026 en interrogeant PostgREST avec un vrai compte conseiller.
--
--  CE QUE L'APP A RÉELLEMENT BESOIN DE LIRE ICI : sa propre ligne, et rien de
--  plus — `select role, conseiller_id ... eq(user_id, moi)`, pour décider des
--  onglets. L'onglet **Utilisateurs** ne passe PAS par PostgREST : il appelle
--  l'Edge Function `admin-utilisateurs` (action `liste`), qui vérifie elle-même
--  que l'appelant est super_admin actif et répond en service_role. Resserrer la
--  policy ne lui retire donc rien.
--
--  Le super admin garde la lecture directe : utile en diagnostic, et il obtient
--  déjà la même liste par l'Edge Function. `est_super_admin()` est
--  `security definer` et lit `profils` hors policies — aucune récursion.
--
--  Idempotent.
-- =============================================================================

drop policy if exists auth_select_profils on public.profils;
drop policy if exists profils_select_soi_ou_super_admin on public.profils;

create policy profils_select_soi_ou_super_admin on public.profils
  for select to authenticated
  using (user_id = auth.uid() or public.est_super_admin());

-- Écritures : toujours aucune policy. Tout passe par l'Edge Function en
-- service_role, qui contrôle le rôle de l'appelant — sans quoi un conseiller
-- pourrait se promouvoir en modifiant sa propre ligne, désormais la seule qu'il
-- voit mais qu'il ne doit toujours pas pouvoir toucher.
