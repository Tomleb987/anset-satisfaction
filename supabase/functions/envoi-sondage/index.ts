// =============================================================================
// ANSET — Edge Function `envoi-sondage`  (réservée au super admin)
// Accès : compte `super_admin` actif (JWT vérifié côté fonction, cf. « Authentification »),
// clé service_role pour la chaîne de passages, ou en-tête `x-anset-cron` pour le cron
// de relance. La clé publishable ne suffit PAS, et un compte `manager` non plus :
// la diffusion appartient à l'Administration.
// -----------------------------------------------------------------------------
// Envoie les invitations au sondage via le RELAIS SMTP Brevo, à partir de la
// table `envois_sondage` (lignes statut_envoi='a_envoyer' de la campagne du mois).
// Chaque invitation porte un LIEN PERSONNALISÉ (agence, conseiller, req, motif) →
// réponse rattachée + lead pré-attribué.
//
// La même fonction porte la RELANCE J+7 (`?relance=1`) : même lien, même gabarit
// d'e-mail, autre texte. Une seconde fonction aurait dupliqué l'authentification,
// la mécanique SMTP, la parallélisation et la chaîne de passages — pour un seul
// paragraphe de différence.
//
// POURQUOI SMTP ET PLUS L'API : Brevo bloque les appels API venant d'une IP
// inconnue et l'IP de sortie des Edge Functions change à chaque invocation
// (liste blanche impossible). Les clés SMTP, elles, ne sont pas soumises à ce
// filtrage IP. Conséquences assumées de ce choix :
//   - pas de template transactionnel Brevo : le HTML est construit ici
//     (voir `email.ts`, source de vérité du visuel) ;
//   - pas de programmation H+2 (`scheduledAt` est une fonctionnalité de l'API) :
//     l'envoi part immédiatement.
//
// Idempotent : une ligne passée à 'envoye' n'est jamais renvoyée, et une ligne
// déjà relancée (`date_relance` non nulle) ne l'est jamais une seconde fois.
//
// UN SEUL CLIC SUFFIT, MÊME SUR UN GROS LOT : les envois sont parallélisés
// (`concurrence` connexions SMTP), et si la fenêtre d'exécution de la fonction
// (150 s en plan Supabase free) approche, la fonction se relance elle-même sur le
// reste du lot (paramètre `chaine`, plafonné à CHAINE_MAX). Une relance n'a lieu
// que si le passage a envoyé au moins un e-mail : une ligne durablement en échec
// ne peut donc pas entretenir une boucle.
//
// CE QUE LA CHAÎNE NE COUVRE PAS : si Supabase tue le worker (HTTP 546), la
// relance n'est jamais émise et la diffusion s'arrête sans bruit. C'est arrivé en
// production le 29/07/2026 avec des lots de 500. D'où deux parades : des lots
// plus petits (LOT_DEFAUT), et la reprise déclenchée par le dashboard quand le
// compteur ne bouge plus. Cette reprise pouvant chevaucher un passage encore
// vivant, chaque ligne est RÉSERVÉE avant envoi (voir `reserver`).
//
// Modes (query string) :
//   (défaut)          envoie le lot 'a_envoyer' de la campagne courante
//   ?relance=1        rappel J+7 aux non-répondants (file = vue v_relances_a_faire)
//   ?campagne=YYYY-MM cible une campagne précise. En relance, l'omettre est le cas
//                     normal : la file est globale et le délai de 7 jours fait le tri.
//   ?limit=N          plafonne le lot par passage (défaut 150, max 500)
//   ?dry=1            simule : ne contacte pas Brevo, ne modifie rien
//   ?test=a@b.pf      TEST : envoie 1 e-mail à cette adresse, ne modifie rien
//                     (combinable avec ?relance=1 pour prévisualiser le rappel)
//   ?chaine=N         usage interne : rang du passage dans la relance automatique
//
// Chaque passage de RELANCE écrit son compte-rendu dans `journal_relances` — même
// les jours sans personne à relancer. C'est la fraîcheur de la dernière ligne qui
// dit à l'app que le cron tourne : une panne d'authentification n'atteint jamais la
// fonction et ne peut donc laisser aucune trace ailleurs.
//
// Secrets/env : BREVO_SMTP_LOGIN, BREVO_SMTP_KEY, BREVO_SENDER_EMAIL,
//               BREVO_SENDER_NAME (optionnel, défaut "ANSET"), FORM_URL,
//               SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto),
//               CRON_SECRET (secret du cron de relance, cf. scripts/relance_j7_cron.sql).
// Env optionnels : BREVO_SMTP_HOST (défaut smtp-relay.brevo.com),
//                  BREVO_SMTP_PORT (défaut 587), BREVO_SMTP_CONCURRENCE (défaut 4),
//                  ALLOWED_ORIGIN (défaut "*").
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@^9";
import {
  SUJET, SUJET_RELANCE,
  htmlInvitation, htmlRelance,
  texteInvitation, texteRelance,
} from "./email.ts";

const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";

// Appelée depuis le dashboard avec un header Authorization : le navigateur
// envoie un préflight OPTIONS, qu'il faut autoriser explicitement.
const CORS = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Max-Age": "86400",
};

// Fenêtre d'exécution d'une Edge Function : 150 s (plan Supabase free), 400 s en payant.
// On s'arrête à 110 s pour laisser le temps de relancer la suite et de répondre.
const BUDGET_MS = 110_000;
// Garde-fou anti-boucle. Relevé de 20 à 80 en même temps que la taille d'un
// passage passait de 500 à 150 : il faut ~22 passages pour un lot de 3200.
const CHAINE_MAX = 80;
// Taille d'un passage. 500 faisait tuer le worker par Supabase (HTTP 546,
// dépassement CPU/mémoire) au bout de 3 ou 4 passages, et la chaîne mourait avec
// lui. 150 laisse une large marge ; il y a juste plus de passages.
const LOT_DEFAUT = 150;
const LOT_MAX = 500;

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj, null, 2), { status, headers: { ...CORS, "Content-Type": "application/json" } });

/**
 * Comparaison de secrets à durée constante. Un `===` sort au premier caractère
 * différent : le temps de réponse laisse alors deviner le secret caractère par
 * caractère. On accepte de divulguer la LONGUEUR (sortie immédiate si elle
 * diffère), ce qui n'aide personne face à un secret tiré au hasard.
 */
const egalConstant = (a: string, b: string): boolean => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
};

interface EnvoiRow {
  id: string;
  req: string | null;
  email: string | null;
  prenom: string | null;
  nom: string | null;
  agence: string | null;
  conseiller_id: string | null;
  motif: string | null;
}

/** Construit le lien personnalisé du formulaire. */
function lienPersonnalise(formUrl: string, row: EnvoiRow): string {
  const u = new URL(formUrl);
  if (row.agence) u.searchParams.set("agence", row.agence);
  if (row.conseiller_id) u.searchParams.set("conseiller", row.conseiller_id);
  if (row.req) u.searchParams.set("req", row.req);
  // Campagne typée (ex. sinistres clos) : le motif pré-remplit et adapte le questionnaire.
  if (row.motif) u.searchParams.set("motif", row.motif);
  return u.toString();
}

/** Adresse « From » au format RFC (nom affiché + adresse validée côté Brevo). */
function expediteur(name: string, email: string): string {
  return `"${name.replace(/"/g, "")}" <${email}>`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const debut = Date.now();
  const url = new URL(req.url);
  const dry = url.searchParams.get("dry") === "1";
  const relance = url.searchParams.get("relance") === "1";
  const testEmail = url.searchParams.get("test");
  const limit = Math.min(parseInt(url.searchParams.get("limit") ?? String(LOT_DEFAUT), 10) || LOT_DEFAUT, LOT_MAX);
  // Rang du passage courant dans la chaîne de relances automatiques (0 = appel du manager).
  const chaine = Math.max(parseInt(url.searchParams.get("chaine") ?? "0", 10) || 0, 0);

  const now = new Date();
  // Diffusion : pas de campagne = celle du mois, c'est le lot qu'on vient
  // d'importer. Relance : pas de campagne = TOUTES, et c'est le cas normal — un
  // lot parti le 28 doit se relancer le 4 du mois suivant, quand la « campagne
  // courante » porte déjà un autre nom.
  const campagneParam = url.searchParams.get("campagne");
  const campagne = campagneParam ?? now.toISOString().slice(0, 7);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  // .trim() : un espace ou un saut de ligne collé dans le champ secret est
  // invisible dans l'UI et fait échouer l'authentification SMTP.
  const smtpHost = Deno.env.get("BREVO_SMTP_HOST")?.trim() || "smtp-relay.brevo.com";
  const smtpPort = parseInt(Deno.env.get("BREVO_SMTP_PORT")?.trim() ?? "587", 10) || 587;
  const smtpLogin = Deno.env.get("BREVO_SMTP_LOGIN")?.trim();
  const smtpKey = Deno.env.get("BREVO_SMTP_KEY")?.trim();
  const formUrl = Deno.env.get("FORM_URL")?.trim();
  const senderEmail = Deno.env.get("BREVO_SENDER_EMAIL")?.trim();
  const senderName = Deno.env.get("BREVO_SENDER_NAME")?.trim() || "ANSET";
  // Envois menés en parallèle. 4 connexions SMTP simultanées passent partout chez
  // Brevo ; descendre à 1 si le relais répond « too many connections ».
  const concurrence = Math.min(Math.max(parseInt(Deno.env.get("BREVO_SMTP_CONCURRENCE")?.trim() ?? "4", 10) || 4, 1), 10);

  if (!supabaseUrl || !serviceRole) return json({ ok: false, error: "Config Supabase incomplète." }, 500);
  if (!formUrl) return json({ ok: false, error: "FORM_URL manquant." }, 500);
  // En SMTP l'expéditeur n'est plus porté par le template : il devient obligatoire.
  if (!dry && (!smtpLogin || !smtpKey)) {
    return json({ ok: false, error: "BREVO_SMTP_LOGIN ou BREVO_SMTP_KEY manquant." }, 500);
  }
  if (!dry && !senderEmail) return json({ ok: false, error: "BREVO_SENDER_EMAIL manquant." }, 500);

  const supabase = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

  // --- Authentification.
  // `verify_jwt=true` ne suffit pas : la passerelle accepte aussi la clé publishable,
  // qui est publique par nature (elle est en clair dans satisfaction_anset.html).
  // Sans le contrôle ci-dessous, n'importe qui pourrait déclencher une diffusion ou
  // s'envoyer une invitation ANSET via ?test=. On exige donc :
  //   - soit un utilisateur réellement connecté (le super admin, depuis le dashboard),
  //   - soit la clé service_role, réservée aux appels internes : la chaîne de
  //     passages (`relancer`) et le cron quotidien de relance J+7
  //     (`scripts/relance_j7_cron.sql`, clé rangée dans Vault).
  //   - soit l'en-tête `x-anset-cron`, secret propre au cron (voir plus bas).
  const bearer = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  // POURQUOI UN SECRET À PART POUR LE CRON. Comparer le bearer à
  // SUPABASE_SERVICE_ROLE_KEY oblige l'appelant à connaître cette clé mot pour mot,
  // et le 30/07/2026 le passage du projet aux nouvelles clés d'API a changé sa
  // valeur sous les pieds du cron : 401 chaque nuit, sans un envoi. `CRON_SECRET`
  // ne dépend d'aucune rotation, et sa fuite ne permet que de DÉCLENCHER une
  // relance — pas de lire la base. La chaîne de passages, elle, continue de
  // s'authentifier par la clé de service : la fonction se compare à sa propre
  // variable d'environnement, il n'y a rien à synchroniser.
  // `.trim()` sur la clé d'environnement : un saut de ligne collé dans le champ
  // secret est invisible dans l'UI et ferait échouer la comparaison.
  const cronSecret = Deno.env.get("CRON_SECRET")?.trim();
  const enteteCron = (req.headers.get("x-anset-cron") ?? "").trim();
  const parCron = !!cronSecret && enteteCron.length > 0 && egalConstant(enteteCron, cronSecret);
  const interne = parCron || (bearer.length > 0 && bearer === serviceRole.trim());
  if (!interne) {
    const { data: auth, error: eAuth } = await supabase.auth.getUser(bearer);
    if (eAuth || !auth?.user) {
      return json({ ok: false, error: "Accès refusé : cette action demande d'être connecté à l'app de pilotage." }, 401);
    }
    // La diffusion fait partie de l'espace Administration, réservé au super admin
    // (un manager ne voit pas l'onglet, mais l'onglet n'est pas une sécurité).
    const { data: profil } = await supabase
      .from("profils").select("role, actif").eq("user_id", auth.user.id).maybeSingle();
    if (!profil || profil.role !== "super_admin" || !profil.actif) {
      return json({ ok: false, error: "Réservé au super administrateur." }, 403);
    }
  }

  /**
   * Compte-rendu du passage dans `journal_relances`. C'est le seul endroit d'où
   * l'app apprend que la relance tourne : `cron.job_run_details` affiche
   * « succeeded » même quand la fonction a répondu 401, et `net._http_response`
   * est purgé au bout de quelques heures.
   *
   * ÉCRIT MÊME QUAND IL N'Y A PERSONNE À RELANCER — c'est tout l'intérêt. Le
   * signal d'alerte côté app est la FRAÎCHEUR de la dernière ligne ; sans ligne
   * les jours creux, un cron mort ressemblerait à un jour sans file.
   *
   * Ne journalise que la relance : la progression d'une diffusion se lit déjà dans
   * `envois_sondage`. Ni en `dry`, ni en `test` — ce ne sont pas des passages.
   * N'échoue jamais bruyamment : perdre la supervision ne doit pas empêcher un
   * rappel de partir.
   */
  const journaliser = async (compte: { envoyes?: number; echecs?: number; message?: string | null }) => {
    if (!relance || dry || testEmail) return;
    try {
      await supabase.from("journal_relances").insert({
        source: chaine > 0 ? "chaine" : parCron ? "cron" : "app",
        passage: chaine + 1,
        envoyes: compte.envoyes ?? 0,
        echecs: compte.echecs ?? 0,
        message: compte.message ?? null,
      });
    } catch { /* supervision dégradée, envoi intact */ }
  };

  // --- Le lot à traiter. Deux sources, une seule mécanique en aval :
  //   diffusion : la table, lignes 'a_envoyer' de la campagne visée ;
  //   relance   : la vue `v_relances_a_faire`, qui PORTE la règle des 7 jours
  //               (envoi parti depuis ≥ 7 j, aucune réponse postérieure à cet
  //               envoi, jamais relancé). Le délai se change dans la migration
  //               20260730120000 et nulle part ailleurs — la fonction et l'app
  //               lisent cette file, elles ne la recalculent pas, sinon le nombre
  //               affiché finit par ne plus correspondre à ce qui part.
  const requete = relance
    ? supabase.from("v_relances_a_faire")
        .select("id, req, email, prenom, nom, agence, conseiller_id, motif")
    : supabase.from("envois_sondage")
        .select("id, req, email, prenom, nom, agence, conseiller_id, motif")
        .eq("campagne", campagne)
        .eq("statut_envoi", "a_envoyer")
        .not("email", "is", null);
  // En relance, cibler une campagne reste possible (diagnostic, rattrapage) mais
  // n'est pas le mode d'emploi : sans paramètre, on prend toute la file.
  if (relance && campagneParam) requete.eq("campagne", campagneParam);

  const { data: rows, error } = await requete.limit(testEmail ? 1 : limit);
  if (error) {
    // Cas typique : la vue `v_relances_a_faire` absente ou renommée. Sans cette
    // trace, la panne serait muette — le cron n'a personne à qui se plaindre.
    await journaliser({ message: `Lecture de la file impossible : ${error.message}` });
    return json({ ok: false, error: error.message }, 500);
  }
  if (!rows || rows.length === 0) {
    // En test, l'absence de lot est un échec : le lien de test se construit à partir d'une ligne réelle.
    if (testEmail) {
      return json({
        ok: false, test: true, relance,
        campagne: relance ? (campagneParam ?? "toutes") : campagne,
        error: relance
          ? "Personne à relancer pour l'instant : impossible de construire un rappel de test à partir d'une ligne réelle."
          : `Aucune ligne « à envoyer » pour la campagne ${campagne} : impossible de construire le lien de test. Importe un lot ou change de campagne.`,
      }, 409);
    }
    if (relance) {
      await journaliser({ message: "Aucun client à relancer." });
      return json({ ok: true, relance: true, traites: 0, message: "Aucun client à relancer." });
    }
    return json({ ok: true, campagne, traites: 0, message: "Aucun envoi 'a_envoyer'." });
  }

  // --- Mode DRY : aperçu, aucune connexion SMTP, aucune écriture.
  if (dry) {
    if (testEmail) {
      const r = rows[0] as EnvoiRow;
      return json({ ok: true, test: true, relance, dry: true, to: testEmail, lien: lienPersonnalise(formUrl, r) });
    }
    return json({
      ok: true, dry: true, relance,
      campagne: relance ? (campagneParam ?? "toutes") : campagne,
      aTraiter: rows.length,
      apercu: (rows as EnvoiRow[]).slice(0, 5).map((r) => ({ email: r.email, prenom: r.prenom, lien: lienPersonnalise(formUrl, r) })),
    });
  }

  // Connexions réutilisées pour tout le lot. La concurrence est ce qui fait tenir
  // un lot de 500 dans la fenêtre de la fonction (cf. BUDGET_MS).
  const transport = nodemailer.createTransport({
    host: smtpHost,
    port: smtpPort,
    secure: smtpPort === 465,      // 465 = TLS direct ; 587 = STARTTLS
    requireTLS: smtpPort !== 465,  // refuse un 587 qui resterait en clair
    auth: { user: smtpLogin!, pass: smtpKey! },
    pool: true,
    maxConnections: concurrence,
  });
  const from = expediteur(senderName, senderEmail!);

  /**
   * Relance la fonction sur elle-même pour traiter le reste du lot, afin qu'un
   * gros envoi se termine sans intervention. On n'attend pas la réponse (elle
   * viendrait 110 s plus tard, hors de notre propre fenêtre) : 1,5 s suffisent à
   * ce que la requête soit partie et que le worker enfant ait démarré.
   */
  const relancer = async (rang: number) => {
    const suite = new URL(`${supabaseUrl}/functions/v1/envoi-sondage`);
    // Le passage suivant doit rester dans le même mode : sans ce report, une
    // chaîne de rappels se transformerait en diffusion d'invitations neuves.
    if (relance) suite.searchParams.set("relance", "1");
    if (!relance || campagneParam) suite.searchParams.set("campagne", campagneParam ?? campagne);
    suite.searchParams.set("limit", String(limit));
    suite.searchParams.set("chaine", String(rang));
    const appel = fetch(suite.toString(), {
      method: "POST",
      headers: { Authorization: `Bearer ${serviceRole}`, apikey: serviceRole },
    }).catch(() => undefined);
    await Promise.race([appel, new Promise((r) => setTimeout(r, 1500))]);
  };

  /** Envoie un e-mail : invitation, ou rappel J+7 selon le mode. */
  const envoyer = async (to: string, lien: string) => {
    await transport.sendMail({
      from, to,
      subject: relance ? SUJET_RELANCE : SUJET,
      html: relance ? htmlRelance(lien) : htmlInvitation(lien),
      text: relance ? texteRelance(lien) : texteInvitation(lien),
    });
  };

  /**
   * RÉSERVATION AVANT ENVOI, conditionnée à l'état qu'on a lu. Si un autre passage
   * a déjà pris la ligne, la condition ne matche plus, rien n'est mis à jour et on
   * la saute. C'est ce qui rend inoffensifs deux passages simultanés — la reprise
   * lancée par le dashboard pendant qu'un passage de fond tourne encore, ou le
   * cron de relance et un clic sur « Relancer » le même jour. Sans cela, le client
   * reçoit deux e-mails et peut répondre deux fois.
   *   diffusion : 'a_envoyer' → 'envoye' + date_envoi
   *   relance   : date_relance null → maintenant. On NE TOUCHE PAS `statut_envoi` :
   *               'envoye' est le dénominateur du taux de réponse, en sortir les
   *               relancés ferait bondir le taux sans une réponse de plus.
   * Retourne true si la ligne est à nous, false si un autre l'a prise ; lève sur
   * erreur SQL.
   */
  const reserver = async (row: EnvoiRow): Promise<boolean> => {
    const maintenant = new Date().toISOString();
    const q = relance
      ? supabase.from("envois_sondage")
          .update({ date_relance: maintenant })
          .eq("id", row.id).is("date_relance", null)
      : supabase.from("envois_sondage")
          .update({ statut_envoi: "envoye", date_envoi: maintenant })
          .eq("id", row.id).eq("statut_envoi", "a_envoyer");
    const { data, error } = await q.select("id");
    if (error) throw new Error(error.message);
    return !!data && data.length > 0;
  };

  /**
   * Échec d'envoi : la ligne doit redevenir traitable, sinon le client est compté
   * comme sollicité sans avoir rien reçu — et en relance il perdrait son unique
   * rappel à cause d'une coupure SMTP. La libération d'une relance ne remet jamais
   * en cause `statut_envoi` : l'invitation, elle, est bien partie.
   */
  const liberer = async (row: EnvoiRow) => {
    await (relance
      ? supabase.from("envois_sondage").update({ date_relance: null }).eq("id", row.id)
      : supabase.from("envois_sondage").update({ statut_envoi: "a_envoyer", date_envoi: null }).eq("id", row.id));
  };

  try {
    // --- Mode TEST : un seul e-mail à l'adresse fournie, rien n'est modifié.
    if (testEmail) {
      const r = rows[0] as EnvoiRow;
      const lien = lienPersonnalise(formUrl, r);
      try {
        await envoyer(testEmail, lien);
      } catch (e) {
        const detail = e instanceof Error ? e.message : String(e);
        return json({ ok: false, test: true, relance, to: testEmail, error: `Brevo (SMTP) a refusé l'envoi : ${detail}` }, 502);
      }
      return json({ ok: true, test: true, relance, to: testEmail, lien, transport: `${smtpHost}:${smtpPort}` });
    }

    // --- Envoi réel : `concurrence` workers puisent dans le même lot, chaque ligne
    // est réservée puis envoyée (reprise sans doublon possible).
    const lot = rows as EnvoiRow[];
    let suivant = 0;
    let envoyes = 0;
    let budgetEpuise = false;
    const erreurs: Array<{ id: string; email: string | null; erreur: unknown }> = [];

    const worker = async () => {
      while (true) {
        // Le budget est vérifié avant chaque envoi : on s'arrête net plutôt que
        // de se faire tuer en cours de route (réponse HTTP perdue côté dashboard).
        if (Date.now() - debut > BUDGET_MS) { budgetEpuise = true; return; }
        const i = suivant++;
        if (i >= lot.length) return;
        const row = lot[i];
        const lien = lienPersonnalise(formUrl, row);

        try {
          if (!await reserver(row)) continue; // déjà prise par un autre passage
        } catch (e) {
          erreurs.push({ id: row.id, email: row.email, erreur: e instanceof Error ? e.message : String(e) });
          continue;
        }

        try {
          await envoyer(row.email!, lien);
        } catch (e) {
          await liberer(row);
          erreurs.push({ id: row.id, email: row.email, erreur: e instanceof Error ? e.message : String(e) });
          continue;
        }
        envoyes++;
      }
    };
    await Promise.all(Array.from({ length: Math.min(concurrence, lot.length) }, worker));

    const traites = envoyes + erreurs.length;
    // Reste-t-il du travail ? Soit on s'est arrêté sur le budget, soit le lot était
    // plafonné par `limit` et d'autres lignes attendent derrière.
    const resteDuTravail = budgetEpuise || (traites >= lot.length && lot.length >= limit);
    // On ne relance que si ce passage a progressé : une ligne qui échoue toujours
    // (adresse morte) ne peut pas déclencher une boucle sans fin.
    const suite = resteDuTravail && envoyes > 0 && chaine < CHAINE_MAX;
    if (suite) await relancer(chaine + 1);

    await journaliser({
      envoyes,
      echecs: erreurs.length,
      // Le premier échec suffit : les 3 200 lignes d'un lot partagent presque
      // toujours la même cause (relais SMTP, quota, identifiants).
      message: erreurs.length
        ? `Premier échec : ${String((erreurs[0] as { erreur: unknown }).erreur).slice(0, 300)}`
        : suite ? "Passage terminé, la suite du lot continue." : null,
    });

    return json({
      ok: erreurs.length === 0,
      relance,
      campagne: relance ? (campagneParam ?? "toutes") : campagne,
      envoyes, echecs: erreurs.length,
      passage: chaine + 1,
      suiteAutomatique: suite,
      restants: Math.max(lot.length - traites, 0),
      erreurs: erreurs.slice(0, 20),
    });
  } finally {
    transport.close();
  }
});
