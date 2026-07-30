-- =============================================================================
--  ANSET — Automatiser la relance J+7 (recommandé).
--
--  Sans ce cron, la relance existe mais dépend d'un clic sur « Relancer » dans
--  l'onglet Administration. Un rappel « à 7 jours » qui attend qu'on y pense n'en
--  est pas un : ce script fait appeler l'Edge Function tous les jours.
--
--  À JOUER UNE FOIS, à la main, dans Supabase → SQL Editor.
--  PAS dans une migration : il faut y coller un secret, qui n'a rien à faire dans
--  le dépôt. Il est rangé dans Vault, pas en clair dans la définition du job
--  (`cron.job` est lisible par le rôle postgres).
--
--  DEUX EN-TÊTES, DEUX RÔLES DISTINCTS — c'est le point à comprendre :
--    · `Authorization` sert uniquement à FRANCHIR LA PASSERELLE, qui exige un
--      jeton valable quand `verify_jwt = true`. On y met la clé PUBLISHABLE, qui
--      est publique par nature (elle est déjà en clair dans satisfaction_anset.html) :
--      elle peut donc rester écrite ici.
--    · `x-anset-cron` sert à PROUVER QU'ON EST LE CRON. C'est le seul secret, et
--      la seule chose rangée dans Vault.
--
--  POURQUOI PAS LA CLÉ service_role DANS LES DEUX RÔLES, comme avant : la fonction
--  comparait le bearer à son propre `SUPABASE_SERVICE_ROLE_KEY`, ce qui obligeait à
--  connaître cette clé mot pour mot. Le 30/07/2026 le passage du projet aux
--  nouvelles clés d'API en a changé la valeur : 401 chaque nuit, sans un envoi, et
--  sans rien pour le signaler. `CRON_SECRET` ne dépend d'aucune rotation, et sa
--  fuite ne permet que de déclencher une relance — pas de lire la base.
--
--  Prérequis : extensions `pg_cron` et `pg_net` (Dashboard → Database → Extensions),
--  et le secret posé côté fonction : `supabase secrets set CRON_SECRET=<valeur>`.
--  La MÊME valeur des deux côtés, sinon la fonction répond 401.
-- =============================================================================

-- --- 1. Extensions ----------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- --- 2. Le secret du cron dans Vault ----------------------------------------
-- UNE SEULE LIGNE À MODIFIER : la valeur de `secret` ci-dessous, identique à celle
-- posée par `supabase secrets set CRON_SECRET=…`. Un « remplacer tout » du marqueur
-- est sans danger : le contrôle porte sur la FORME de la valeur, pas sur une
-- comparaison au marqueur — sinon remplacer partout écraserait le contrôle
-- lui-même, qui comparerait le secret à lui-même et refuserait de s'exécuter alors
-- qu'on vient de faire ce qu'il demandait.
-- Rejouable : la seconde exécution met le secret à jour au lieu d'en créer un autre.
do $$
declare
  secret text := 'COLLER_ICI_LA_VALEUR_DE_CRON_SECRET';
  id     uuid;
begin
  if secret like '%COLLER%' or length(secret) < 24 then
    raise exception 'Renseigne la valeur de CRON_SECRET (>= 24 caractères) à la place du marqueur.';
  end if;

  select s.id into id from vault.secrets s where s.name = 'cron_secret';
  if id is null then
    perform vault.create_secret(secret, 'cron_secret', 'En-tête x-anset-cron de la relance J+7');
  else
    perform vault.update_secret(id, secret);
  end if;
end $$;

-- --- 3. Ménage : l'ancienne clé service_role n'a plus à traîner dans Vault ---
-- Elle n'y sert plus à rien depuis que le cron s'authentifie par en-tête, et un
-- secret inutile reste un secret exposé.
delete from vault.secrets where name = 'service_role_key';

-- --- 4. Le job quotidien -----------------------------------------------------
-- 05:00 UTC = 19:00 à Tahiti (UTC−10), la veille au soir. Heure choisie pour que
-- le rappel arrive en soirée locale plutôt qu'en pleine nuit.
--
-- Aucun paramètre `campagne` : la file est globale et le délai de 7 jours fait le
-- tri. Une invitation partie le 28 doit pouvoir être relancée le 4 du mois suivant.
--
-- Le job tourne tous les jours et ne fait rien les jours sans file : la fonction
-- répond « Aucun client à relancer » sans ouvrir de connexion SMTP — mais elle
-- écrit quand même sa ligne dans `journal_relances`, et c'est cette ligne que
-- l'onglet Administration surveille.
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
                 -- Clé publishable : publique, uniquement là pour la passerelle.
                 'Authorization', 'Bearer sb_publishable_TuAsNz3zhWxY1cRjEwtZOA_FPVfwzQK',
                 -- Le vrai secret, déchiffré depuis Vault à chaque passage.
                 'x-anset-cron',  (select decrypted_secret
                                     from vault.decrypted_secrets
                                    where name = 'cron_secret')
               ),
    timeout_milliseconds := 120000
  );
  $job$
);

-- --- 5. Vérifier -------------------------------------------------------------
-- Le job est-il planifié ?
--   select jobid, jobname, schedule, active from cron.job where jobname = 'relance-sondage-j7';
--
-- LE CONTRÔLE QUI COMPTE — le compte-rendu du dernier passage. `cron.job_run_details`
-- ne suffit PAS : il affiche « succeeded » même quand la fonction a répondu 401,
-- parce que `net.http_post` ne fait qu'empiler la requête.
--   select debut, source, envoyes, echecs, message
--     from public.journal_relances order by debut desc limit 10;
--
-- La file du moment (ce que le prochain passage enverra) :
--   select count(*) from public.v_relances_a_faire;
--
-- Tester sans attendre 05:00 et sans envoyer un seul e-mail : ajouter &dry=1 à
-- l'URL ci-dessus dans un appel manuel. Un `dry` n'écrit PAS dans le journal (ce
-- n'est pas un passage), mais un HTTP 200 avec `"relance": true` prouve que
-- l'authentification par en-tête fonctionne :
--   select net.http_post(
--     url := 'https://xizitftoejfxaizztzeu.supabase.co/functions/v1/envoi-sondage?relance=1&dry=1',
--     headers := jsonb_build_object('Content-Type','application/json',
--       'Authorization','Bearer sb_publishable_TuAsNz3zhWxY1cRjEwtZOA_FPVfwzQK',
--       'x-anset-cron', (select decrypted_secret from vault.decrypted_secrets where name='cron_secret'))) as id;
--   -- puis, quelques secondes plus tard :
--   select status_code, content from net._http_response order by id desc limit 1;
--
-- Pour arrêter l'automatisation sans rien casser (le bouton manuel reste) :
--   select cron.unschedule('relance-sondage-j7');
