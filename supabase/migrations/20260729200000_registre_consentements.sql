-- =============================================================================
--  ANSET — Registre des consentements au recontact commercial (opt-in).
--
--  POURQUOI UNE TABLE À PART. `leads.consentement_source` porte déjà une preuve,
--  mais elle ne couvre que les ACCORDS : un lead n'existe que si le client a dit
--  oui ET laissé des coordonnées. Or l'obligation d'« accountability » suppose de
--  pouvoir démontrer trois choses que cette colonne ne permet pas :
--    1. qu'on a demandé le consentement (et avec quel texte exactement) ;
--    2. ce que le client a répondu — y compris un REFUS, preuve qu'on l'a respecté
--       et qu'un rappel ultérieur serait une faute ;
--    3. que la preuve survit à l'effacement du lead. `scripts/purge_rgpd.sql`
--       supprime les leads `sans_suite` / `ne_pas_contacter` : purger la preuve
--       avec la donnée reviendrait à ne plus pouvoir justifier une prospection
--       passée. D'où l'absence VOLONTAIRE de `on delete cascade` et de FK vers
--       `leads` : le registre ne dépend d'aucune donnée susceptible d'être purgée.
--
--  CE QUI N'EST PAS STOCKÉ, ET POURQUOI. Ni adresse IP, ni empreinte de
--  navigateur : minimisation. L'IP n'apporterait rien qu'un horodatage et un
--  `response_id` ne prouvent déjà, et une IP hachée sans sel secret reste
--  ré-identifiable (l'espace IPv4 s'énumère). Aucune coordonnée non plus — le
--  registre dit QU'UN consentement a été donné et sur quel texte, pas qui est
--  joignable où : ça, c'est `leads`, et c'est purgeable.
--
--  UNE LIGNE PAR SOUMISSION. `response_id` est unique : une re-soumission du même
--  formulaire ne crée pas un second enregistrement (upsert idempotent, comme
--  `reponses_satisfaction` et `leads`). Un client qui remplirait DEUX invitations
--  différentes a deux `response_id`, donc deux lignes — c'est voulu : ce sont deux
--  actes de consentement distincts, chacun horodaté.
--
--  Additif et idempotent.
-- =============================================================================

create table if not exists public.registre_consentements (
  id              bigserial primary key,
  response_id     uuid        not null unique,
  -- Décision du client. `false` = refus explicite : le registre existe surtout
  -- pour ça. Non nullable : une soumission sans réponse à la question ne doit pas
  -- produire de ligne (rien à prouver), la fonction n'en écrit pas.
  consenti        boolean     not null,
  date_decision   timestamptz not null default now(),
  -- Finalité pour laquelle le consentement est recueilli. Une seule aujourd'hui ;
  -- la colonne existe pour qu'un second usage (newsletter, enquête) ne vienne pas
  -- se confondre avec la prospection dans le même registre.
  finalite        text        not null default 'prospection_commerciale',
  -- Texte EXACTEMENT tel qu'affiché au client, et sa version. Sans le texte, on
  -- prouve un clic, pas un consentement éclairé.
  texte_presente  text        not null,
  version_texte   text        not null,
  canal           text        not null default 'formulaire_web',
  -- Contexte de collecte, utile pour retrouver l'invitation d'origine.
  campagne        text,
  req             text,
  motif           text,
  -- Moyens de contact FOURNIS (présence, pas valeur) : permet de vérifier qu'un
  -- accord était exploitable sans dupliquer de PII dans le registre.
  a_donne_tel     boolean     not null default false,
  a_donne_email   boolean     not null default false,
  created_at      timestamptz not null default now()
);

comment on table public.registre_consentements is
  'Registre de preuve des consentements au recontact commercial (accords ET refus). Ne contient aucune coordonnée ni adresse IP. N''est pas purgé avec les leads : c''est la preuve, pas la donnée.';

create index if not exists idx_registre_date     on public.registre_consentements (date_decision desc);
create index if not exists idx_registre_consenti on public.registre_consentements (consenti);
create index if not exists idx_registre_campagne on public.registre_consentements (campagne);

alter table public.registre_consentements enable row level security;

-- Lecture réservée au super admin : c'est un registre de conformité, consulté pour
-- répondre à une demande d'exercice de droits ou à un contrôle — pas un outil de
-- prospection. Les managers n'en ont pas besoin pour travailler leurs leads.
drop policy if exists admin_select_registre on public.registre_consentements;
create policy admin_select_registre on public.registre_consentements
  for select to authenticated using (public.est_super_admin());

-- AUCUNE policy d'écriture : seule l'Edge Function `submit-sondage` écrit ici, en
-- service_role (qui bypasse la RLS). Un registre de preuve qu'un client pourrait
-- alimenter ou corriger depuis le navigateur ne prouverait rien.
