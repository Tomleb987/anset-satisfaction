-- =============================================================================
-- ANSET — Purge RGPD des leads (minimisation / limitation de conservation)
-- À jouer une fois (SQL Editor). Planifie une purge mensuelle des leads
-- classés sans_suite / ne_pas_contacter au-delà du délai de conservation.
--
-- ⚠️ DÉLAI À VALIDER par le référent RGPD (ici : 12 mois depuis la dernière MAJ).
-- =============================================================================

create extension if not exists pg_cron;

-- Idempotent : retire un éventuel job existant du même nom.
select cron.unschedule('anset-purge-leads-rgpd')
where exists (select 1 from cron.job where jobname = 'anset-purge-leads-rgpd');

-- Purge mensuelle : le 1er du mois à 03:00.
select cron.schedule(
  'anset-purge-leads-rgpd',
  '0 3 1 * *',
  $$
  with cibles as (
    select id from public.leads
    where statut in ('sans_suite', 'ne_pas_contacter')
      and updated_at < now() - interval '12 months'
  )
  -- Supprime d'abord les notes liées (FK), puis les leads.
  , del_notes as (
    delete from public.lead_notes
    where lead_id in (select id from cibles)
    returning 1
  )
  delete from public.leads
  where id in (select id from cibles);
  $$
);

-- Vérifs :
-- select jobid, jobname, schedule, active from cron.job;
-- select * from cron.job_run_details order by start_time desc limit 5;
