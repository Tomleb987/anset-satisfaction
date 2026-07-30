-- =============================================================================
--  ANSET — Jetons de réinitialisation de mot de passe (libre-service).
--
--  POURQUOI PAS LE FLUX NATIF DE SUPABASE. `resetPasswordForEmail` suppose un SMTP
--  configuré côté Auth. Il n'y en a aucun sur ce projet : l'expéditeur intégré est
--  plafonné à 2 e-mails par heure et ne sert que les membres du projet — les 24
--  conseillers n'auraient jamais reçu leur lien. Le relais SMTP Brevo, lui, est en
--  service et éprouvé (3 264 invitations parties le 29/07/2026). On réutilise donc
--  ce chemin, au prix de cette table.
--
--  CE QUI EST STOCKÉ, ET SURTOUT CE QUI NE L'EST PAS. Le jeton n'est JAMAIS
--  enregistré : seule son empreinte SHA-256 l'est. Une fuite de cette table ne
--  permet donc pas de prendre la main sur un compte — il faudrait inverser le
--  hachage d'une valeur de 32 octets tirée au hasard. C'est la même raison qui
--  interdit de « retrouver » un lien perdu : personne, pas même le super admin, ne
--  peut le relire. Ni IP ni user-agent : ils n'apporteraient rien qu'un horodatage
--  ne dise déjà, et ce sont des données personnelles de plus à justifier.
--
--  USAGE UNIQUE ET DURÉE COURTE. `utilise_le` est posé AVANT le changement de mot
--  de passe, sous condition qu'il soit nul — même idiome que la réservation d'une
--  relance (migration 20260730120000) : deux clics simultanés sur le même lien ne
--  peuvent pas aboutir deux fois. `expire_le` vaut une heure : assez pour aller
--  chercher son e-mail, trop peu pour qu'un lien oublié dans une boîte partagée
--  reste utilisable des semaines plus tard.
--
--  AUCUNE POLICY. La table n'est lue et écrite que par l'Edge Function en
--  service_role. Un jeton de réinitialisation visible depuis le navigateur, même
--  haché, même en lecture seule, n'aurait aucune raison d'exister.
--
--  Additif et idempotent.
-- =============================================================================

create table if not exists public.jetons_mot_de_passe (
  id           bigserial   primary key,
  user_id      uuid        not null references auth.users(id) on delete cascade,
  -- Empreinte hexadécimale SHA-256 du jeton. `unique` : deux demandes ne peuvent
  -- pas produire la même valeur, et une collision serait un signal, pas un détail.
  jeton_sha256 text        not null unique,
  cree_le      timestamptz not null default now(),
  expire_le    timestamptz not null,
  utilise_le   timestamptz
);

comment on table public.jetons_mot_de_passe is
  'Jetons de réinitialisation de mot de passe, stockés uniquement sous forme d''empreinte SHA-256. Usage unique (utilise_le), validité 1 h. Écrite et lue exclusivement par l''Edge Function mot-de-passe-oublie en service_role.';

-- Recherche par empreinte : le chemin critique de la validation d'un lien.
create index if not exists idx_jetons_mdp_empreinte on public.jetons_mot_de_passe (jeton_sha256);
-- Limitation du nombre de demandes par compte et par heure.
create index if not exists idx_jetons_mdp_user      on public.jetons_mot_de_passe (user_id, cree_le desc);

alter table public.jetons_mot_de_passe enable row level security;
-- Volontairement AUCUNE policy : personne d'autre que le service_role n'a à voir
-- cette table, pas même un super admin (il n'y a rien d'exploitable à y lire, et
-- une lecture autorisée ne servirait qu'à donner l'illusion du contraire).

-- --- Purge ------------------------------------------------------------------
-- Un jeton expiré ou consommé n'a plus d'utilité : le garder ne documente rien
-- d'utile et allonge une table qu'on veut minuscule. Appelée par l'Edge Function à
-- chaque demande, ce qui évite un cron pour si peu.
create or replace function public.purger_jetons_mot_de_passe()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.jetons_mot_de_passe
   where expire_le < now() - interval '1 day'
      or utilise_le is not null and utilise_le < now() - interval '1 day';
$$;

revoke all on function public.purger_jetons_mot_de_passe() from public;
