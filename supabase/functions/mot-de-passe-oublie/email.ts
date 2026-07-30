// =============================================================================
// ANSET — E-mail de réinitialisation de mot de passe (interne).
//
// POURQUOI CE GABARIT N'EST PAS CELUI DE `envoi-sondage/email.ts`, qui est pourtant
// désigné comme source de vérité du visuel : celui-là s'adresse à un CLIENT et porte
// à ce titre le bloc d'information RGPD (responsable du traitement, durée de
// conservation, contact DPO, politique de confidentialité). Ce message-ci s'adresse
// à un COLLABORATEUR au sujet de son propre accès à un outil interne : y coller des
// mentions sur le traitement des données clients serait faux, et les diluerait là où
// elles comptent vraiment. Deux publics, deux gabarits — la duplication est ici le
// choix correct, pas un oubli.
//
// Contraintes techniques identiques : tables et styles inline, aucune image
// distante, version texte obligatoire (certains clients refusent le HTML, et le lien
// doit rester atteignable).
// =============================================================================

const MARINE = "#16233c";
const CIEL = "#2f6f9f";

function esc(v: string): string {
  return v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export const SUJET = "ANSET — réinitialisation de votre mot de passe";

/** Durée de validité annoncée : doit rester alignée sur `expire_le` côté fonction. */
export const VALIDITE = "1 heure";

export function htmlReinitialisation(lien: string, prenom: string): string {
  const l = esc(lien);
  return `<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#eef2f7;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2f7;padding:24px 12px;">
<tr><td align="center">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:14px;overflow:hidden;font-family:Helvetica,Arial,sans-serif;">
    <tr><td style="background:${MARINE};padding:22px 28px;">
      <div style="color:#ffffff;font-size:19px;font-weight:700;letter-spacing:.3px;">ANSET</div>
      <div style="color:#c9d6e6;font-size:13px;margin-top:2px;">Application de pilotage</div>
    </td></tr>
    <tr><td style="padding:28px;">
      <h1 style="margin:0 0 14px;font-size:20px;color:${MARINE};">Réinitialiser votre mot de passe</h1>
      <p style="margin:0 0 14px;font-size:15px;line-height:1.55;color:#33415a;">
        ${prenom ? `Ia Ora Na ${esc(prenom)},` : "Ia Ora Na,"} une réinitialisation de mot de passe a été
        demandée pour votre accès à l'application de pilotage ANSET.
      </p>
      <p style="margin:0 0 22px;font-size:15px;line-height:1.55;color:#33415a;">
        Ce lien est valable <strong style="color:${MARINE};">${VALIDITE}</strong> et ne peut servir
        qu'une seule fois&nbsp;:
      </p>
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto 20px;">
        <tr><td align="center" style="background:${CIEL};border-radius:9px;">
          <a href="${l}" style="display:inline-block;padding:13px 28px;color:#ffffff;font-size:15px;font-weight:700;text-decoration:none;">Choisir un nouveau mot de passe</a>
        </td></tr>
      </table>
      <p style="margin:0 0 6px;font-size:13px;line-height:1.5;color:#6b7a91;">
        Si le bouton ne fonctionne pas, copiez cette adresse dans votre navigateur&nbsp;:
      </p>
      <p style="margin:0 0 20px;font-size:12px;line-height:1.5;word-break:break-all;color:${CIEL};">${l}</p>
      <p style="margin:0;padding-top:16px;border-top:1px solid #e3e9f1;font-size:13px;line-height:1.55;color:#6b7a91;">
        <strong style="color:${MARINE};">Vous n'avez rien demandé&nbsp;?</strong> Ignorez ce message&nbsp;:
        votre mot de passe actuel reste valable, et ce lien expirera de lui-même. Prévenez toutefois
        votre administrateur si vous recevez plusieurs messages de ce type.
      </p>
    </td></tr>
    <tr><td style="background:#f6f9fc;padding:16px 28px;font-size:12px;color:#8899ad;">
      Message automatique — outil interne ANSET Assurances. Merci de ne pas y répondre.
    </td></tr>
  </table>
</td></tr></table>
</body></html>`;
}

export function texteReinitialisation(lien: string, prenom: string): string {
  return [
    prenom ? `Ia Ora Na ${prenom},` : "Ia Ora Na,",
    "",
    "Une réinitialisation de mot de passe a été demandée pour votre accès à",
    "l'application de pilotage ANSET.",
    "",
    `Ce lien est valable ${VALIDITE} et ne peut servir qu'une seule fois :`,
    lien,
    "",
    "Vous n'avez rien demandé ? Ignorez ce message : votre mot de passe actuel",
    "reste valable et ce lien expirera de lui-même. Prévenez votre administrateur",
    "si vous recevez plusieurs messages de ce type.",
    "",
    "Message automatique — outil interne ANSET Assurances. Merci de ne pas y répondre.",
  ].join("\n");
}
