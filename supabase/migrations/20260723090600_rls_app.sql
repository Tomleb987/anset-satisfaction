-- =============================================================================
-- ANSET — Policies RLS manquantes sur les tables préexistantes.
-- Constat (2026-07-23) : RLS activée mais AUCUNE policy sur reponses_satisfaction,
-- leads, lead_notes, conseillers → refus par défaut pour `authenticated`
-- (dashboard et prospection vides). On ajoute lecture + écritures applicatives.
-- Les écritures serveur (submit-sondage) passent en service_role (bypass RLS).
-- Idempotent.
-- =============================================================================

-- --- reponses_satisfaction : lecture (dashboard) ---------------------------
drop policy if exists auth_select_reponses on public.reponses_satisfaction;
create policy auth_select_reponses on public.reponses_satisfaction
  for select to authenticated using (true);

-- --- leads : lecture + traitement (prospection) ----------------------------
drop policy if exists auth_select_leads on public.leads;
create policy auth_select_leads on public.leads for select to authenticated using (true);
drop policy if exists auth_update_leads on public.leads;
create policy auth_update_leads on public.leads for update to authenticated using (true) with check (true);
drop policy if exists auth_insert_leads on public.leads;
create policy auth_insert_leads on public.leads for insert to authenticated with check (true);

-- --- lead_notes : lecture + ajout de notes ---------------------------------
drop policy if exists auth_select_lead_notes on public.lead_notes;
create policy auth_select_lead_notes on public.lead_notes for select to authenticated using (true);
drop policy if exists auth_insert_lead_notes on public.lead_notes;
create policy auth_insert_lead_notes on public.lead_notes for insert to authenticated with check (true);

-- --- conseillers : lecture + auto-création à l'import requête ---------------
drop policy if exists auth_select_conseillers on public.conseillers;
create policy auth_select_conseillers on public.conseillers for select to authenticated using (true);
drop policy if exists auth_insert_conseillers on public.conseillers;
create policy auth_insert_conseillers on public.conseillers for insert to authenticated with check (true);
drop policy if exists auth_update_conseillers on public.conseillers;
create policy auth_update_conseillers on public.conseillers for update to authenticated using (true) with check (true);
