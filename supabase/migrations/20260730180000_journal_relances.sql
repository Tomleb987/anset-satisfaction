-- =============================================================================
--  ANSET — Journal des passages de relance J+7.
--
--  POURQUOI CETTE TABLE. Le cron de relance pouvait échouer chaque nuit sans que
--  rien ne le signale — constaté le 30/07/2026 : la clé rangée dans Vault n'était
--  plus celle qu'attendait l'Edge Function, réponse 401, aucun rappel envoyé, et
--  aucune trace côté app. Les deux endroits où l'on aurait pu croire trouver la
--  réponse ne la donnent pas :
--    · `cron.job_run_details` affiche « succeeded » même sur un 401 : `net.http_post`
--      ne fait qu'EMPILER la requête, son succès ne dit rien de la réponse HTTP ;
--    · `net._http_response` porte bien le code, mais pg_net le purge au bout de
--      quelques heures — au matin, la preuve a disparu.
--
--  C'EST DONC LA FONCTION QUI JOURNALISE, et le signal d'alerte est l'ABSENCE de
--  ligne récente, pas un code d'erreur. Ce choix est ce qui rend le dispositif
--  utile : il couvre justement les pannes qui n'atteignent jamais la fonction
--  (401, passerelle, clé tournée), lesquelles ne peuvent par construction rien
--  écrire nulle part. Une ligne est écrite À CHAQUE passage, Y COMPRIS les jours
--  sans personne à relancer : sans cela, un jour creux serait indistinguable d'une
--  panne et la fraîcheur deviendrait inexploitable.
--
--  CE QUE LA TABLE N'EST PAS : un journal d'envoi. Qui a été relancé et quand se
--  lit dans `envois_sondage.date_relance`, ligne à ligne. Ici on ne garde que le
--  compte-rendu du passage — de quoi répondre à « est-ce que ça tourne ? ».
--
--  Additif et idempotent.
-- =============================================================================

create table if not exists public.journal_relances (
  id       bigserial   primary key,
  debut    timestamptz not null default now(),
  -- Qui a déclenché le passage. 'chaine' = la fonction s'appelant elle-même pour
  -- la suite d'un gros lot : distingué des deux autres pour qu'une chaîne de cinq
  -- passages ne se lise pas comme cinq relances quotidiennes.
  source   text        not null check (source in ('cron', 'app', 'chaine')),
  passage  int         not null default 1,
  envoyes  int         not null default 0,
  echecs   int         not null default 0,
  message  text
);

comment on table public.journal_relances is
  'Compte-rendu de chaque passage de relance J+7, écrit par l''Edge Function envoi-sondage. Une ligne même les jours sans personne à relancer : c''est la FRAÎCHEUR de la dernière ligne qui signale une panne, pas son contenu.';

create index if not exists idx_journal_relances_debut on public.journal_relances (debut desc);

alter table public.journal_relances enable row level security;

-- Lecture réservée au super admin : la carte « Relance » vit dans l'espace
-- Administration, qui lui est déjà réservé.
drop policy if exists admin_select_journal_relances on public.journal_relances;
create policy admin_select_journal_relances on public.journal_relances
  for select to authenticated using (public.est_super_admin());

grant select on public.journal_relances to authenticated;

-- AUCUNE policy d'écriture : seule l'Edge Function écrit ici, en service_role (qui
-- bypasse la RLS). Un journal de supervision que le navigateur pourrait alimenter
-- ne prouverait pas que le cron tourne.
