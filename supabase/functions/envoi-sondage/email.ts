// =============================================================================
// ANSET — Contenu des e-mails du sondage : invitation et relance J+7.
// -----------------------------------------------------------------------------
// SOURCE DE VÉRITÉ du visuel de l'e-mail depuis le passage en SMTP : le relais
// SMTP Brevo n'exploite pas le template transactionnel, c'est donc la fonction
// qui construit le HTML et remplace le lien personnalisé.
// `scripts/brevo_invitation.html` en est une copie de lecture/aperçu.
// Charte : voir la skill anset-webdesign (bleu #1C509D, mauve #715689).
//
// Les deux e-mails partagent le même gabarit (en-tête, bouton, mentions RGPD) :
// seuls le titre, le corps et la petite note changent. Dupliquer le gabarit
// garantirait qu'une correction de mentions légales soit faite dans un seul des
// deux.
// =============================================================================

export const SUJET = "Votre avis sur ANSET en 1 minute";
export const SUJET_RELANCE = "Votre avis sur ANSET — il est encore temps";

/** Échappe une valeur destinée à du HTML (le lien contient des « & » de séparation). */
function esc(v: string): string {
  return v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

interface Contenu {
  titre: string;
  /** Paragraphes du corps, en HTML (le premier est mis en avant). */
  corps: string[];
  /** Libellé du bouton. */
  cta: string;
  /** Petite ligne sous le bouton. */
  note: string;
}

const INVITATION: Contenu = {
  titre: "Votre avis compte pour nous",
  corps: [
    `Chez <strong style="color:#16233c;">ANSET</strong>, votre satisfaction est notre priorité.
     Pourriez-vous prendre <strong style="color:#16233c;">une petite minute</strong> pour nous dire
     comment s'est passée votre expérience&nbsp;? Vos réponses nous aident à améliorer nos services au quotidien.`,
  ],
  cta: "Donner mon avis",
  note: "Le questionnaire est court et confidentiel.",
};

const RELANCE: Contenu = {
  titre: "Il vous reste une minute&nbsp;?",
  corps: [
    `Nous vous avons sollicité il y a quelques jours au sujet de votre expérience chez
     <strong style="color:#16233c;">ANSET</strong>. Vous n'avez peut-être pas eu le temps d'y répondre&nbsp;:
     le questionnaire est toujours ouvert.`,
    `Votre retour compte, même s'il est bref&nbsp;— et même s'il est critique.`,
  ],
  cta: "Répondre au questionnaire",
  // Promesse explicite : c'est le seul rappel. Elle nous engage, et la mécanique
  // la tient (une relance par invitation, cf. migration 20260730120000).
  note: "C'est notre seul rappel — vous ne recevrez pas d'autre message à ce sujet.",
};

/** Version texte (les clients qui refusent le HTML doivent garder le lien). */
function texte(c: Contenu, lien: string, intro: string[]): string {
  return [
    "Ia Ora Na,",
    "",
    ...intro,
    "",
    `${c.cta} : ${lien}`,
    "",
    c.note.replace(/&nbsp;/g, " ").replace(/&#8239;/g, " "),
    "",
    "Cet e-mail vous est adressé par ANSET (responsable du traitement) dans le cadre de la",
    "mesure de la satisfaction client. Vos données sont hébergées dans l'Union européenne et",
    "conservées 12 mois maximum. Droit d'accès, de rectification et de suppression : dpo@anset.pf",
    "Politique de confidentialité : https://www.anset.pf/assets/pdf/rgpd.pdf",
    "",
    "ANSET Assurances — Tahiti, Polynésie française",
  ].join("\n");
}

/** Gabarit HTML complet (tables + styles inline : contrainte des clients mail). */
function gabarit(c: Contenu, lien: string): string {
  const l = esc(lien);
  const paras = c.corps
    .map((p) => `<p style="margin:0 0 20px;font-size:15px;line-height:1.6;color:#5d6b83;">${p}</p>`)
    .join("\n        ");
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F7F9FC;margin:0;padding:24px 0;font-family:'DM Sans',Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
  <tr><td align="center">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;background:#ffffff;border:1px solid #dde3ec;border-radius:16px;overflow:hidden;">
      <tr><td style="height:4px;background:#1C509D;background:linear-gradient(90deg,#1C509D,#715689);"></td></tr>
      <tr><td align="center" style="padding:28px 40px 8px;">
        <img src="https://anset-satisfaction.vercel.app/anset_brand_logo_TAHITI.png" alt="ANSET Assurances" width="150" style="display:block;height:auto;max-width:150px;" />
      </td></tr>
      <tr><td style="padding:8px 40px 0;">
        <h1 style="margin:16px 0 6px;font-size:22px;line-height:1.3;color:#16233c;font-weight:800;">${c.titre}</h1>
        <p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#16233c;">Ia Ora Na,</p>
        ${paras}
      </td></tr>
      <tr><td align="center" style="padding:6px 40px 4px;">
        <table role="presentation" cellpadding="0" cellspacing="0"><tr>
          <td align="center" style="border-radius:12px;background:#1C509D;">
            <a href="${l}" target="_blank"
               style="display:inline-block;padding:15px 34px;font-size:16px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:12px;">
              ${c.cta}
            </a>
          </td>
        </tr></table>
      </td></tr>
      <tr><td align="center" style="padding:10px 40px 0;">
        <p style="margin:0;font-size:12.5px;color:#93a1b8;">${c.note}</p>
      </td></tr>
      <tr><td style="padding:18px 40px 0;">
        <p style="margin:0;font-size:12px;line-height:1.5;color:#93a1b8;">
          Le bouton ne fonctionne pas&nbsp;? Copiez ce lien dans votre navigateur&nbsp;:<br>
          <a href="${l}" style="color:#1C509D;word-break:break-all;">${l}</a>
        </p>
      </td></tr>
      <tr><td style="padding:22px 40px 0;"><div style="border-top:1px solid #eef2f7;"></div></td></tr>
      <tr><td style="padding:16px 40px 30px;">
        <p style="margin:0;font-size:11.5px;line-height:1.6;color:#93a1b8;">
          Cet e-mail vous est adressé par <strong style="color:#5d6b83;">ANSET</strong> (responsable du traitement)
          dans le cadre de la mesure de la satisfaction client. Vos données sont hébergées dans l'Union européenne
          et conservées 12&nbsp;mois maximum. Vous disposez d'un droit d'accès, de rectification et de suppression&nbsp;:
          <a href="mailto:dpo@anset.pf" style="color:#1C509D;">dpo@anset.pf</a> &middot;
          <a href="https://www.anset.pf/assets/pdf/rgpd.pdf" style="color:#1C509D;">Politique de confidentialité</a>.
        </p>
      </td></tr>
    </table>
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;">
      <tr><td align="center" style="padding:16px 20px;">
        <p style="margin:0;font-size:11.5px;color:#93a1b8;font-family:'DM Sans',Segoe UI,Roboto,Arial,sans-serif;">
          ANSET Assurances — Tahiti, Polynésie française
        </p>
      </td></tr>
    </table>
  </td></tr>
</table>`;
}

export const htmlInvitation = (lien: string) => gabarit(INVITATION, lien);
export const htmlRelance = (lien: string) => gabarit(RELANCE, lien);

export const texteInvitation = (lien: string) =>
  texte(INVITATION, lien, [
    "Chez ANSET, votre satisfaction est notre priorité. Pourriez-vous prendre une petite",
    "minute pour nous dire comment s'est passée votre expérience ? Vos réponses nous",
    "aident à améliorer nos services au quotidien.",
  ]);

export const texteRelance = (lien: string) =>
  texte(RELANCE, lien, [
    "Nous vous avons sollicité il y a quelques jours au sujet de votre expérience chez",
    "ANSET. Vous n'avez peut-être pas eu le temps d'y répondre : le questionnaire est",
    "toujours ouvert. Votre retour compte, même s'il est bref — et même s'il est critique.",
  ]);
