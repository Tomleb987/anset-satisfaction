// =============================================================================
// ANSET — Edge Function `mot-de-passe-oublie`  (endpoint PUBLIC, verify_jwt=false)
// -----------------------------------------------------------------------------
// Libre-service de réinitialisation, en deux temps :
//   {action:"demande", identifiant}        → envoie un lien à usage unique
//   {action:"changer", jeton, motdepasse}  → pose le nouveau mot de passe
//
// PUBLIC PAR NÉCESSITÉ : quelqu'un qui a perdu son mot de passe ne peut pas
// s'authentifier pour demander à le changer. Tout le durcissement porte donc sur ce
// que la fonction accepte de RÉVÉLER et sur ce qu'elle laisse RÉPÉTER.
//
// 1. AUCUNE ÉNUMÉRATION DE COMPTES. `demande` répond toujours la même chose, dans le
//    même délai apparent, que l'identifiant existe ou non. Une réponse « compte
//    inconnu » transformerait cet endpoint en annuaire du personnel : on saurait qui
//    travaille chez ANSET en essayant des prénoms.
//
// 2. LE JETON N'EST JAMAIS STOCKÉ, seulement son empreinte SHA-256 (cf. migration
//    20260730200000). Conséquence assumée : un lien perdu est irrécupérable, y
//    compris pour le super admin. C'est le prix d'une table qui ne vaut rien si
//    elle fuit.
//
// 3. USAGE UNIQUE PAR RÉSERVATION AVANT ACTION. `utilise_le` est posé sous condition
//    qu'il soit nul AVANT d'appeler l'API d'administration — même idiome que la
//    réservation d'une relance dans `envoi-sondage`. Deux ouvertures simultanées du
//    même lien ne peuvent pas aboutir deux fois ; si la pose du mot de passe échoue
//    ensuite, le jeton est libéré pour que la personne puisse réessayer.
//
// 4. DÉBIT LIMITÉ PAR COMPTE. Au-delà de DEMANDES_MAX par heure, plus rien ne part —
//    mais la réponse reste identique. Sans cela, un tiers pourrait inonder la boîte
//    d'un collègue en rejouant le formulaire, et brûler le quota Brevo au passage.
//
// 5. UN COMPTE DÉSACTIVÉ NE REÇOIT RIEN. Il est banni côté auth : lui envoyer un
//    lien serait promettre un accès qui sera refusé.
//
// Secrets : SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto), BREVO_SMTP_LOGIN,
//           BREVO_SMTP_KEY, BREVO_SENDER_EMAIL, BREVO_SENDER_NAME (optionnel).
// Env optionnels : APP_URL (adresse de l'app, défaut ci-dessous),
//                  BREVO_SMTP_HOST / BREVO_SMTP_PORT, ALLOWED_ORIGIN.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@^9";
import { SUJET, htmlReinitialisation, texteReinitialisation } from "./email.ts";

const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";
const APP_URL = Deno.env.get("APP_URL")?.trim()
  || "https://anset-satisfaction.vercel.app/satisfaction_anset";
const DOMAINE_COMPTES = "anset.pf";
/** Validité du lien. À garder aligné avec `VALIDITE` annoncé dans l'e-mail. */
const VALIDITE_MS = 60 * 60 * 1000;
/** Demandes acceptées par compte et par heure. */
const DEMANDES_MAX = 3;
/** Plancher du nouveau mot de passe, aligné sur le formulaire de l'onglet Utilisateurs. */
const MDP_MIN = 8;

const CORS = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, authorization, apikey",
  "Access-Control-Max-Age": "86400",
};

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj, null, 2), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

/** Réponse unique de `demande` : la même pour un compte connu, inconnu, désactivé
 *  ou en dépassement de débit. C'est elle qui empêche l'énumération. */
const REPONSE_NEUTRE = {
  ok: true,
  message: "Si ce compte existe, un e-mail vient d'être envoyé avec un lien de réinitialisation. "
    + "Pensez à regarder vos indésirables.",
};

const empreinte = async (jeton: string): Promise<string> => {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(jeton));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
};

/** Jeton d'URL : 32 octets tirés au hasard, en base64url (pas de caractère à échapper). */
function nouveauJeton(): string {
  const octets = new Uint8Array(32);
  crypto.getRandomValues(octets);
  return btoa(String.fromCharCode(...octets)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** `manon.marrocq` comme `manon.marrocq@anset.pf` : la page de connexion complète le
 *  domaine, l'e-mail de rappel ne doit donc pas être plus exigeant qu'elle. */
function adresseCompte(brut: unknown): string {
  const s = String(brut ?? "").trim().toLowerCase();
  if (!s) return "";
  return s.includes("@") ? s : `${s}@${DOMAINE_COMPTES}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) return json({ ok: false, error: "Config Supabase incomplète." }, 500);
  const supabase = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

  let corps: Record<string, unknown>;
  try {
    corps = await req.json();
  } catch {
    return json({ ok: false, error: "Corps de requête illisible." }, 400);
  }
  const action = String(corps.action ?? "");

  // ==========================================================================
  //  DEMANDE — envoi du lien
  // ==========================================================================
  if (action === "demande") {
    const email = adresseCompte(corps.identifiant);
    // Réponse neutre même sur une saisie vide : rien ne doit distinguer les cas.
    if (!email || !email.includes("@")) return json(REPONSE_NEUTRE);

    // Ménage opportuniste : évite un cron pour une table qui doit rester minuscule.
    await supabase.rpc("purger_jetons_mot_de_passe").then(() => {}, () => {});

    const { data: profil } = await supabase
      .from("profils").select("user_id, nom, actif").eq("email", email).maybeSingle();

    // Compte inconnu ou désactivé : on s'arrête ici, sans rien dire de plus.
    if (!profil || !profil.actif) return json(REPONSE_NEUTRE);

    const depuis = new Date(Date.now() - VALIDITE_MS).toISOString();
    const { count } = await supabase
      .from("jetons_mot_de_passe")
      .select("id", { count: "exact", head: true })
      .eq("user_id", profil.user_id).gte("cree_le", depuis);
    if ((count ?? 0) >= DEMANDES_MAX) return json(REPONSE_NEUTRE);

    const jeton = nouveauJeton();
    const { error: eIns } = await supabase.from("jetons_mot_de_passe").insert({
      user_id: profil.user_id,
      jeton_sha256: await empreinte(jeton),
      expire_le: new Date(Date.now() + VALIDITE_MS).toISOString(),
    });
    // Un échec d'écriture ne doit pas devenir un signal exploitable : on garde la
    // réponse neutre, la trace de l'erreur reste dans les logs de la fonction.
    if (eIns) {
      console.error("jetons_mot_de_passe:", eIns.message);
      return json(REPONSE_NEUTRE);
    }

    const smtpLogin = Deno.env.get("BREVO_SMTP_LOGIN")?.trim();
    const smtpKey = Deno.env.get("BREVO_SMTP_KEY")?.trim();
    const senderEmail = Deno.env.get("BREVO_SENDER_EMAIL")?.trim();
    const senderName = Deno.env.get("BREVO_SENDER_NAME")?.trim() || "ANSET";
    if (!smtpLogin || !smtpKey || !senderEmail) {
      console.error("SMTP Brevo incomplet : lien créé mais non envoyé.");
      return json(REPONSE_NEUTRE);
    }

    // Le jeton voyage dans le FRAGMENT (#) et non dans la query string : un
    // fragment n'est pas transmis au serveur, n'apparaît donc ni dans les logs
    // d'accès ni dans un en-tête Referer vers un tiers.
    const lien = `${APP_URL}#recuperation=${jeton}`;
    const prenom = String(profil.nom ?? "").trim().split(/\s+/)[0] ?? "";
    const port = parseInt(Deno.env.get("BREVO_SMTP_PORT")?.trim() ?? "587", 10) || 587;
    const transport = nodemailer.createTransport({
      host: Deno.env.get("BREVO_SMTP_HOST")?.trim() || "smtp-relay.brevo.com",
      port,
      secure: port === 465,
      requireTLS: port !== 465,
      auth: { user: smtpLogin, pass: smtpKey },
    });
    try {
      await transport.sendMail({
        from: `"${senderName}" <${senderEmail}>`,
        to: email,
        subject: SUJET,
        html: htmlReinitialisation(lien, prenom),
        text: texteReinitialisation(lien, prenom),
      });
    } catch (e) {
      // Idem : l'échec SMTP ne se raconte pas au visiteur. Le jeton posé expirera.
      console.error("SMTP:", e instanceof Error ? e.message : String(e));
    } finally {
      transport.close();
    }
    return json(REPONSE_NEUTRE);
  }

  // ==========================================================================
  //  CHANGER — pose du nouveau mot de passe
  // ==========================================================================
  if (action === "changer") {
    const jeton = String(corps.jeton ?? "").trim();
    const motdepasse = String(corps.motdepasse ?? "");
    if (!jeton) return json({ ok: false, error: "Lien de réinitialisation absent." }, 400);
    if (motdepasse.length < MDP_MIN) {
      return json({ ok: false, error: `Le mot de passe doit faire au moins ${MDP_MIN} caractères.` }, 400);
    }

    const { data: ligne } = await supabase
      .from("jetons_mot_de_passe")
      .select("id, user_id, expire_le, utilise_le")
      .eq("jeton_sha256", await empreinte(jeton))
      .maybeSingle();

    // Un seul message pour « inconnu », « déjà utilisé » et « expiré » : les
    // distinguer renseignerait sur l'existence et l'historique d'un lien.
    const perime = !ligne || ligne.utilise_le || new Date(ligne.expire_le).getTime() < Date.now();
    if (perime) {
      return json({
        ok: false,
        error: "Ce lien n'est plus valable : il a peut-être déjà servi, ou il a plus d'une heure. "
          + "Demandez-en un nouveau depuis l'écran de connexion.",
      }, 400);
    }

    // Réservation avant action : deux ouvertures simultanées du même lien ne peuvent
    // pas aboutir toutes les deux.
    const { data: reserve } = await supabase
      .from("jetons_mot_de_passe")
      .update({ utilise_le: new Date().toISOString() })
      .eq("id", ligne.id).is("utilise_le", null)
      .select("id");
    if (!reserve || reserve.length === 0) {
      return json({ ok: false, error: "Ce lien vient d'être utilisé. Demandez-en un nouveau." }, 409);
    }

    const { error: eMdp } = await supabase.auth.admin.updateUserById(
      ligne.user_id, { password: motdepasse });
    if (eMdp) {
      // Libération : sans elle, une erreur transitoire consommerait définitivement
      // le seul lien de la personne.
      await supabase.from("jetons_mot_de_passe")
        .update({ utilise_le: null }).eq("id", ligne.id);
      return json({ ok: false, error: `Changement refusé : ${eMdp.message}` }, 400);
    }

    // Les autres liens en attente de ce compte n'ont plus de raison de vivre : le
    // mot de passe vient de changer, et un vieux lien encore valable serait une
    // porte ouverte de plus.
    await supabase.from("jetons_mot_de_passe")
      .update({ utilise_le: new Date().toISOString() })
      .eq("user_id", ligne.user_id).is("utilise_le", null);

    const { data: profil } = await supabase
      .from("profils").select("email").eq("user_id", ligne.user_id).maybeSingle();
    return json({
      ok: true,
      email: profil?.email ?? null,
      message: "Mot de passe modifié. Vous pouvez vous connecter.",
    });
  }

  return json({ ok: false, error: "Action inconnue." }, 400);
});
