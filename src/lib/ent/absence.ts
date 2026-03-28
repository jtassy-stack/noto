/**
 * Absence notification — pre-filled message for PCN parents.
 * Sends via ENTCore Conversation API.
 */

import type { ConversationCredentials } from "./conversation";
import type { Child } from "@/types";

export type AbsenceMotif = "maladie" | "rdv_medical" | "raison_familiale" | "autre";

export const MOTIF_LABELS: Record<AbsenceMotif, string> = {
  maladie: "Maladie",
  rdv_medical: "Rendez-vous médical",
  raison_familiale: "Raison familiale",
  autre: "Autre",
};

export interface AbsenceRequest {
  child: Child;
  date: string; // "lundi 31 mars 2026"
  dateEnd?: string; // for multi-day
  motif: AbsenceMotif;
  motifDetail?: string; // free text for "autre"
  parentName: string;
}

function buildAbsenceSubject(child: Child, date: string): string {
  return `Absence de ${child.firstName} ${child.lastName} - ${child.className} - ${date}`;
}

function buildAbsenceBody(req: AbsenceRequest): string {
  const motifText = req.motif === "autre" && req.motifDetail
    ? req.motifDetail
    : MOTIF_LABELS[req.motif];

  const dateText = req.dateEnd
    ? `du ${req.date} au ${req.dateEnd}`
    : `le ${req.date}`;

  return [
    `<p>Madame, Monsieur,</p>`,
    `<p>Je vous informe que mon enfant <strong>${req.child.firstName} ${req.child.lastName}</strong>, `,
    `en classe de <strong>${req.child.className}</strong>, `,
    `sera absent(e) ${dateText}.</p>`,
    `<p>Motif : ${motifText}</p>`,
    `<p>Je vous prie d'agréer l'expression de mes salutations distinguées.</p>`,
    `<p>${req.parentName}</p>`,
  ].join("\n");
}

/**
 * Find the teacher and director group IDs for a child's class.
 * Searches visible recipients for matching group names.
 */
async function findRecipients(
  creds: ConversationCredentials,
  child: Child
): Promise<string[]> {
  // Re-login
  await fetch(`${creds.apiBaseUrl}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
    redirect: "follow",
  });

  // Search for visible recipients
  const res = await fetch(`${creds.apiBaseUrl}/conversation/visible`, {
    headers: { Accept: "application/json" },
  });

  if (!res.ok) {
    console.warn("[nōto] Failed to fetch visible recipients:", res.status);
    return [];
  }

  const data = await res.json() as {
    groups?: Array<{ id: string; name: string }>;
    users?: Array<{ id: string; displayName: string; profile?: string }>;
  };

  const groups = data.groups ?? [];
  const users = data.users ?? [];
  const recipients: string[] = [];

  // Extract class name without teacher (e.g., "CM1 - CM2 A" from "CM1 - CM2 A - M. Lucas TOLOTTA")
  const classParts = child.className.split(" - ");
  const classShort = classParts.length > 2
    ? classParts.slice(0, -1).join(" - ") // remove teacher name
    : child.className;

  // Find teacher group for this class
  for (const g of groups) {
    if (g.name.includes("Enseignants") && g.name.includes(classShort)) {
      recipients.push(g.id);
      console.log("[nōto] Found teacher group:", g.name);
    }
  }

  // Find individual teachers matching the class
  const teacherName = classParts[classParts.length - 1]?.replace(/^(M\.|Mme|M)\s*/, "").trim();
  if (teacherName) {
    for (const u of users) {
      if (u.profile === "Teacher" && u.displayName.toUpperCase().includes(teacherName.toUpperCase())) {
        recipients.push(u.id);
        console.log("[nōto] Found teacher:", u.displayName);
      }
    }
  }

  // Find director/directrice
  for (const u of users) {
    if (u.profile === "Teacher" && (
      u.displayName.toLowerCase().includes("direct") ||
      u.displayName.toLowerCase().includes("princip")
    )) {
      recipients.push(u.id);
      console.log("[nōto] Found director:", u.displayName);
    }
  }

  // Fallback: if no specific recipients found, use the school-wide teacher group
  if (recipients.length === 0) {
    for (const g of groups) {
      if (g.name.includes("Enseignants") && g.name.includes("DOMBASLE")) {
        recipients.push(g.id);
        console.log("[nōto] Fallback to school teacher group:", g.name);
        break;
      }
    }
  }

  return [...new Set(recipients)]; // deduplicate
}

/**
 * Send an absence notification via PCN Conversation API.
 */
export async function sendAbsenceNotification(
  creds: ConversationCredentials,
  req: AbsenceRequest
): Promise<void> {
  // Find recipients
  const recipients = await findRecipients(creds, req.child);

  if (recipients.length === 0) {
    throw new Error("Aucun destinataire trouvé. Vérifiez la classe de l'enfant.");
  }

  console.log("[nōto] Sending absence to", recipients.length, "recipients");

  const subject = buildAbsenceSubject(req.child, req.date);
  const body = buildAbsenceBody(req);

  // Step 1: Create draft
  const draftRes = await fetch(`${creds.apiBaseUrl}/conversation/draft`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({
      subject,
      body,
      to: recipients,
      cc: [],
      bcc: [],
    }),
  });

  if (!draftRes.ok) {
    throw new Error(`Erreur création brouillon (${draftRes.status})`);
  }

  const draft = await draftRes.json() as { id: string };
  console.log("[nōto] Draft created:", draft.id);

  // Step 2: Send the draft
  const sendRes = await fetch(`${creds.apiBaseUrl}/conversation/send?id=${draft.id}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      subject,
      body,
      to: recipients,
      cc: [],
      bcc: [],
    }),
  });

  if (!sendRes.ok) {
    throw new Error(`Erreur envoi message (${sendRes.status})`);
  }

  console.log("[nōto] Absence notification sent!");
}
