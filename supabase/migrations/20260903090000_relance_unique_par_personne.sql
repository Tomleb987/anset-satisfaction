-- =============================================================================
--  ANSET — Au plus une relance par personne tous les 6 mois.
--
--  CE QUI CHANGE, ET POURQUOI. `date_relance` garantissait déjà qu'une invitation
--  n'était jamais relancée deux fois. Mais l'unicité d'`envois_sondage` porte sur
--  (campagne, email) : un client présent dans les requêtes de juin, juillet et août
--  a trois invitations, donc trois relances — chacune parfaitement « unique », pour
--  une personne sollicitée trois fois. Avec les ~3 800 doublons relevés le 29/07,
--  c'est l'essentiel du volume de rappels, et la cause du dépassement du forfait
--  Brevo constaté le 03/09/2026.
--
--  LA RÈGLE DEVIENT : un e-mail donné reçoit au plus UN rappel par FENÊTRE GLISSANTE
--  DE 6 MOIS, quel que soit le nombre de campagnes où il apparaît. Pas « jamais
--  deux » : un client relancé en juin 2026 redevient relançable en janvier 2027, sur
--  une invitation de MOINS DE 90 JOURS. On rationne la fréquence, on ne ferme pas
--  la porte.
--
--  POURQUOI GLISSANTE ET NON CALENDAIRE (semestre, année) : une borne calendaire
--  rouvre la file d'un coup pour tout le monde au 1er janvier, et le pic retombe sur
--  le forfait du même mois. La fenêtre glissante étale les réouvertures au fil de
--  l'eau, chacun au rythme de sa propre dernière relance.
--
--  DEUX GARDE-FOUS, ET L'UN SANS L'AUTRE NE SUFFIT PAS :
--
--    1. `not exists` sur `date_relance` récente — écarte les personnes relancées
--       lors d'un passage ANTÉRIEUR. Ne protège pas d'un doublon À L'INTÉRIEUR d'un
--       même passage : les lignes sont lues d'un coup, avant que la première
--       réservation n'ait eu lieu, donc deux campagnes du même client passeraient
--       toutes deux le filtre et partiraient toutes deux.
--
--    2. `distinct on (email)` — ne laisse qu'une ligne par personne dans la file,
--       ce qui ferme précisément ce trou. On garde l'invitation LA PLUS RÉCENTE :
--       c'est celle dont le contexte (agence, conseiller, motif) est encore juste,
--       et celle dont le lien renvoie au sinistre que le client a en tête.
--
--    3. `date_envoi` de moins de 90 jours — et ce n'est PAS une précaution de
--       principe. `distinct on` ne réserve qu'une ligne par personne ; les autres
--       campagnes du même client restent `date_relance is null` À JAMAIS, puisque
--       plus rien ne les fera remonter en tête de file. Sans borne haute, la
--       réouverture des 6 mois repêche ce stock d'orphelines : vérifié sur pile
--       locale, la file proposait une invitation de 243 jours — un « rappel » sur un
--       sinistre clos depuis des mois, avec un lien qui y renvoie. Vu les ~3 800
--       doublons du 29/07, ces orphelines seraient l'essentiel de ce que la file
--       rouvre. La borne les abandonne définitivement, et c'est l'intention : une
--       invitation que personne n'a relancée en 3 mois n'est plus d'actualité.
--
--       90 jours = trois campagnes mensuelles. De quoi absorber un cron arrêté
--       plusieurs semaines sans perdre un rappel encore légitime.
--
--  OÙ SE CHANGENT LES DÉLAIS : les trois `interval` ci-dessous, ici et nulle part
--  ailleurs. La vue reste la source unique — l'Edge Function et le compteur de
--  l'onglet Administration lisent tous deux cette file, donc ce qui s'affiche est
--  exactement ce qui partira.
--
--  CE QUE ÇA COÛTE. Un client relancé en juin sur un sinistre auto ne sera pas
--  relancé sur son sinistre habitation de septembre. Et une invitation restée en
--  file d'attente plus de 90 jours ne recevra jamais son rappel. C'est assumé :
--  l'invitation initiale, elle, part toujours à chaque campagne — seul le RAPPEL
--  est rationné.
--
--  CE QUI NE CHANGE PAS : le délai de 7 jours, la règle « n'a pas répondu à CETTE
--  invitation », `statut_envoi` intact (il reste le dénominateur du taux de
--  réponse), et la réservation avant envoi côté Edge Function.
--
--  Idempotent.
-- =============================================================================

-- Le `not exists` cherche « cet e-mail a-t-il été relancé récemment, où que ce
-- soit ». Index partiel : seules les lignes déjà relancées sont indexées, soit une
-- petite fraction de la table, et c'est exactement l'ensemble interrogé.
create index if not exists idx_envois_email_relance
  on public.envois_sondage (email, date_relance)
  where date_relance is not null;

create or replace view public.v_relances_a_faire
with (security_invoker = on) as
select distinct on (e.email)
       e.id, e.req, e.campagne, e.email, e.prenom, e.nom,
       e.agence, e.zone, e.conseiller_id, e.motif, e.date_envoi
  from public.envois_sondage e
 where e.statut_envoi = 'envoye'
   and e.email       is not null
   and e.req         is not null
   and e.date_envoi  is not null
   and e.date_relance is null
   and e.date_envoi <= now() - interval '7 days'
   -- Borne haute : au-delà, l'invitation est périmée et sort de la file pour de
   -- bon (cf. garde-fou 3 — sans ceci, la réouverture des 6 mois relance sur des
   -- invitations de 8 mois).
   and e.date_envoi >= now() - interval '90 days'
   -- Cette invitation-ci est-elle restée sans réponse ? (« sans réponse » se juge
   -- par rapport à date_envoi : un même req revient d'une campagne à l'autre, une
   -- réponse antérieure ne dit rien sur l'invitation en cours.)
   and not exists (
     select 1 from public.reponses_satisfaction r
      where r.req = e.req
        and r.date_reponse >= e.date_envoi
   )
   -- Cette PERSONNE a-t-elle eu un rappel dans les 6 derniers mois, dans n'importe
   -- quelle campagne ? Au-delà, elle redevient relançable.
   and not exists (
     select 1 from public.envois_sondage p
      where p.email = e.email
        and p.date_relance is not null
        and p.date_relance > now() - interval '6 months'
   )
 -- Obligatoire pour `distinct on`, et porte la décision : à personne égale, c'est
 -- l'invitation la plus récente qui l'emporte.
 order by e.email, e.date_envoi desc;

comment on view public.v_relances_a_faire is
  'File des rappels J+7 : au plus UNE relance par personne (e-mail) sur 6 mois glissants, toutes campagnes confondues, sur son invitation la plus récente restée sans réponse et vieille de moins de 90 jours. Source unique des trois délais — J+7, plafond par personne, péremption.';

-- Les DEUX lecteurs de la file, et il en faut deux : l'onglet Administration lit
-- sous le JWT de Thomas (`authenticated`), l'Edge Function sous la clé
-- `service_role` — c'est elle qui envoie réellement les rappels. Sur base rejouée
-- à blanc, `service_role` n'héritait d'aucun SELECT : le cron aurait été muet.
grant select on public.v_relances_a_faire to authenticated;
grant select on public.v_relances_a_faire to service_role;
