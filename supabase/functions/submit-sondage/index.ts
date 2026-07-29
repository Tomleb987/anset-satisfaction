// =============================================================================
// ANSET — Edge Function `submit-sondage`  (endpoint PUBLIC, verify_jwt=false)
// -----------------------------------------------------------------------------
// Reçoit la soumission du formulaire HTML public, vérifie l'anti-spam Turnstile
// côté serveur, puis écrit via service_role dans :
//   - reponses_satisfaction : TOUJOURS
//   - leads                 : si consentement + (téléphone ou email)
//
// Aucune insertion anonyme directe : seule la service_role écrit (bypass RLS).
// Les policies RLS `authenticated` existantes restent inchangées.
//
// Secrets : TURNSTILE_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto).
// Env optionnel : ALLOWED_ORIGIN (restreindre le CORS ; défaut "*").
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";

const CORS = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Max-Age": "86400",
};

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// --- Coercition robuste ------------------------------------------------------
function toInt(v: unknown): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = parseInt(String(v), 10);
  return Number.isFinite(n) ? n : null;
}
function toBool(v: unknown): boolean {
  return v === true || v === "true" || v === "oui" || v === 1 || v === "1";
}
function trimOrNull(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s === "" ? null : s;
}
function npsCategorie(nps: number | null): string | null {
  if (nps === null) return null;
  if (nps >= 9) return "promoteur";
  if (nps >= 7) return "passif";
  return "detracteur";
}
// Motifs d'interaction acceptés (alignés formulaire / dashboard). Toute autre valeur → null.
const MOTIFS = new Set(["souscription", "sinistre", "gestion", "reclamation", "information", "autre"]);
function motifOrNull(v: unknown): string | null {
  const s = trimOrNull(v)?.toLowerCase() ?? null;
  return s && MOTIFS.has(s) ? s : null;
}
// Réponse « réseaux sociaux » : suit la marque / intéressé / non.
const RESEAUX = new Set(["oui", "interesse", "non"]);
function reseauxOrNull(v: unknown): string | null {
  const s = trimOrNull(v)?.toLowerCase() ?? null;
  return s && RESEAUX.has(s) ? s : null;
}

// --- Vérification Turnstile (Cloudflare) -------------------------------------
async function verifyTurnstile(token: string | null, ip: string | null): Promise<boolean> {
  const secret = Deno.env.get("TURNSTILE_SECRET");
  if (!secret) {
    console.error("TURNSTILE_SECRET absent");
    return false;
  }
  if (!token) return false;
  const form = new FormData();
  form.append("secret", secret);
  form.append("response", token);
  if (ip) form.append("remoteip", ip);
  const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    body: form,
  });
  if (!res.ok) return false;
  const data = await res.json();
  return data?.success === true;
}

Deno.serve(async (req: Request) => {
  // Préflight CORS.
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) return json({ ok: false, error: "Config serveur incomplète." }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Corps JSON invalide." }, 400);
  }

  // 1) Anti-spam : sans token Turnstile valide, on n'écrit RIEN.
  const ip = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for");
  const ok = await verifyTurnstile(trimOrNull(body.turnstileToken), ip);
  if (!ok) return json({ ok: false, error: "Échec de la vérification anti-spam." }, 400);

  // 2) Mapping du payload.
  const now = new Date().toISOString();
  const response_id = crypto.randomUUID();
  let campagne = now.slice(0, 7); // YYYY-MM (recalé sur l'envoi si req connu)

  const nps = toInt(body.nps);
  let motif = motifOrNull(body.motif); // recalé sur l'envoi si la campagne est typée
  const consent = toBool(body.consent);
  const prenom = trimOrNull(body.prenom);
  const telephone = trimOrNull(body.telephone);
  const email = trimOrNull(body.email);
  const req_param = trimOrNull(body.req);
  const agence = trimOrNull(body.agence);

  const supabase = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

  try {
    // Attribution : le lien perso porte conseiller_id/req ; envois_sondage est la
    // source canonique (agence/zone/conseiller/campagne). La zone suit l'agence CHOISIE.
    let conseiller_id: string | null = trimOrNull(body.conseiller_id);
    let zone: string | null = null;

    if (req_param) {
      // Un même `req` peut exister dans PLUSIEURS campagnes (le même fichier source
      // importé sur deux mois). Sans tri, la ligne retenue était arbitraire : les
      // réponses aux invitations de juin se sont retrouvées classées en juillet, ce
      // qui vidait le taux de réponse des deux campagnes (constaté le 29/07/2026).
      // On retient donc l'envoi RÉELLEMENT parti le plus récent — c'est lui qui a
      // produit le lien sur lequel le client vient de cliquer. `nullsFirst: false`
      // renvoie les lignes jamais envoyées en dernier.
      const { data: envoi } = await supabase
        .from("envois_sondage")
        .select("agence, zone, conseiller_id, campagne, motif, date_envoi")
        .eq("req", req_param)
        .order("date_envoi", { ascending: false, nullsFirst: false })
        .limit(1)
        .maybeSingle();
      if (envoi) {
        if (!conseiller_id) conseiller_id = envoi.conseiller_id ?? null;
        if (envoi.campagne) campagne = envoi.campagne; // caler sur la campagne d'origine
        zone = envoi.zone ?? null;
        // La campagne typée (ex. sinistres clos) fait foi sur le motif.
        const envoiMotif = motifOrNull(envoi.motif);
        if (envoiMotif) motif = envoiMotif;
      }
    }
    // La zone suit l'agence renseignée (source de vérité = table agences).
    if (agence) {
      const { data: ag } = await supabase
        .from("agences").select("zone").eq("nom", agence).limit(1).maybeSingle();
      if (ag?.zone) zone = ag.zone;
    }

    // 3) reponses_satisfaction — TOUJOURS. Colonnes non collectées = null.
    const { error: eSat } = await supabase
      .from("reponses_satisfaction")
      .upsert(
        {
          response_id,
          date_reponse: now,
          campagne,
          agence,
          zone,
          conseiller_id,
          req: req_param,
          motif,
          interaction_recente: toBool(body.interaction),
          nps,
          nps_categorie: npsCategorie(nps),
          satisfaction_globale: toInt(body.csat_global),
          note_conseiller: toInt(body.csat_conseiller),
          note_accueil: toInt(body.csat_accueil),
          // Champs spécifiques sinistre : conservés uniquement quand le motif est "sinistre".
          sat_sinistre:        motif === "sinistre" ? toInt(body.sat_sinistre) : null,
          delai_indemnisation: motif === "sinistre" ? toInt(body.delai_indemnisation) : null,
          reseaux_sociaux: reseauxOrNull(body.reseaux_sociaux),
          commentaire: trimOrNull(body.commentaire),
          a_consenti_recontact: consent,
        },
        { onConflict: "response_id", ignoreDuplicates: true },
      );
    if (eSat) throw new Error("reponses_satisfaction: " + eSat.message);

    // 4) leads — seulement si consentement ET au moins un moyen de contact.
    let leadCree = false;
    if (consent && (telephone || email)) {
      // Le lead a une FK conseillers.id : ne garder l'attribution que si le slug existe.
      let lead_conseiller: string | null = conseiller_id;
      if (lead_conseiller) {
        const { data: c } = await supabase
          .from("conseillers").select("id").eq("id", lead_conseiller).maybeSingle();
        if (!c) lead_conseiller = null; // slug inconnu → pas de pré-attribution (évite l'échec FK)
      }

      const { error: eLead } = await supabase
        .from("leads")
        .upsert(
          {
            response_id,
            prenom,
            telephone,
            email,
            agence,
            conseiller_id: lead_conseiller,
            // statut ('nouveau') et tentatives (0) : defaults en base.
            date_consentement: now,
            campagne,
            consentement_source: { source: "form_html", date: now, req: req_param, motif },
          },
          { onConflict: "response_id", ignoreDuplicates: true },
        );
      if (eLead) throw new Error("leads: " + eLead.message);
      leadCree = true;
    }

    return json({ ok: true, lead: leadCree });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("submit-sondage:", message);
    // Message générique côté client (jamais de détail interne ni d'autres données).
    return json({ ok: false, error: "Enregistrement impossible pour le moment." }, 500);
  }
});
