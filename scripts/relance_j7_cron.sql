-- =============================================================================
--  ANSET — Automatiser la relance J+7 (facultatif mais recommandé).
--
--  Sans ce cron, la relance existe mais dépend d'un clic sur « Relancer » dans
--  l'onglet Administration. Un rappel « à 7 jours » qui attend qu'on y pense n'en
--  est pas un : ce script fait appeler l'Edge Function tous les jours.
--
--  À JOUER UNE FOIS, à la main, dans Supabase → SQL Editor.
--  PAS dans une migration : il faut y coller la clé `service_role`, qui n'a rien
--  à faire dans le dépôt. Elle est ici rangée dans Vault, pas en clair dans la
--  définition du job (`cron.job` est lisible par le rôle postgres).
--
--  Prérequis : extensions `pg_cron` et `pg_net` (Dashboard → Database → Extensions).
-- =============================================================================

-- --- 1. Extensions ----------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- --- 2. La clé service_role dans Vault --------------------------------------
-- REMPLACER la valeur ci-dessous (Settings → API → service_role), puis exécuter.
-- Rejouable : la seconde exécution met le secret à jour au lieu d'en créer un autre.
do $$
declare
  cle text := 'COLLER_ICI_LA_CLE_SERVICE_ROLE';
  id  uuid;
begin
  if cle = 'COLLER_ICI_LA_CLE_SERVICE_ROLE' then
    raise exception 'Renseigne la clé service_role avant d''exécuter ce script.';
  end if;
  select s.id into id from vault.secrets s where s.name = 'service_role_key';
  if id is null then
    perform vault.create_secret(cle, 'service_role_key', 'Appel interne de envoi-sondage par le cron de relance');
  else
    perform vault.update_secret(id, cle);
  end if;
end $$;

-- --- 3. Le job quotidien -----------------------------------------------------
-- 05:00 UTC = 19:00 à Tahiti (UTC−10), la veille au soir. Heure choisie pour que
-- le rappel arrive en soirée locale plutôt qu'en pleine nuit.
--
-- Aucun paramètre `campagne` : la file est globale et le délai de 7 jours fait le
-- tri. Une invitation partie le 28 doit pouvoir être relancée le 4 du mois suivant.
--
-- Le job tourne tous les jours et ne fait rien les jours sans file : la fonction
-- répond « Aucun client à relancer » sans ouvrir de connexion SMTP.
select cron.unschedule('relance-sondage-j7')
 where exists (select 1 from cron.job where jobname = 'relance-sondage-j7');

select cron.schedule(
  'relance-sondage-j7',
  '0 5 * * *',
  $job$
  select net.http_post(
    url     := 'https://xizitftoejfxaizztzeu.supabase.co/functions/v1/envoi-sondage?relance=1',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || (select decrypted_secret
                                                  from vault.decrypted_secrets
                                                 where name = 'service_role_key')
               ),
    timeout_milliseconds := 120000
  );
  $job$
);

-- --- 4. Vérifier -------------------------------------------------------------
-- Le job est-il planifié ?
--   select jobid, jobname, schedule, active from cron.job where jobname = 'relance-sondage-j7';
-- Les dernières exécutions et leur résultat :
--   select start_time, status, return_message from cron.job_run_details
--    where jobid = (select jobid from cron.job where jobname = 'relance-sondage-j7')
--    order by start_time desc limit 10;
-- La file du moment (ce que le prochain passage enverra) :
--   select count(*) from public.v_relances_a_faire;
--
-- Pour arrêter l'automatisation sans rien casser (le bouton manuel reste) :
--   select cron.unschedule('relance-sondage-j7');
