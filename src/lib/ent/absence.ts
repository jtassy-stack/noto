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
  date: string;
  dateEnd?: string;
  motif: AbsenceMotif;
  motifDetail?: string;
  parentName: string;
}

function buildSubject(child: Child, date: string): string {
  return `Absence de ${child.firstName} ${child.lastName} - ${child.className} - ${date}`;
}

function buildBody(req: AbsenceRequest): string {
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

async function ensureLogin(creds: ConversationCredentials): Promise<void> {
  await fetch(`${creds.apiBaseUrl}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
    redirect: "follow",
  });
}

async function findRecipients(
  creds: ConversationCredentials,
  child: Child
): Promise<string[]> {
  const res = await fetch(`${creds.apiBaseUrl}/conversation/visible`, {
    headers: { Accept: "application/json" },
  });

  if (!res.ok) {
    const text = await res.text();
    console.warn("[nōto] visible failed:", res.status, text.substring(0, 80));
    // If HTML (session expired), re-login and retry
    if (text.includes("<!DOCTYPE") || res.status === 302) {
      await ensureLogin(creds);
      const retry = await fetch(`${creds.apiBaseUrl}/conversation/visible`, {
        headers: { Accept: "application/json" },
      });
      if (!retry.ok) return [];
      const data = await retry.json();
      return extractRecipients(data, child);
    }
    return [];
  }

  const data = await res.json();
  return extractRecipients(data, child);
}

function extractRecipients(
  data: { groups?: Array<{ id: string; name: string }>; users?: Array<{ id: string; displayName: string; profile?: string }> },
  child: Child
): string[] {
  const groups = data.groups ?? [];
  const users = data.users ?? [];
  const recipients: string[] = [];

  const classParts = child.className.split(" - ");
  const classShort = classParts.length > 2
    ? classParts.slice(0, -1).join(" - ").trim()
    : classParts[0]?.trim() ?? "";

  // Teacher group for this class
  for (const g of groups) {
    if (g.name.includes("Enseignants") && classShort && g.name.includes(classShort)) {
      recipients.push(g.id);
      console.log("[nōto] Found teacher group:", g.name);
    }
  }

  // Individual teacher
  const teacherName = classParts[classParts.length - 1]?.replace(/^(M\.|Mme|M)\s*/i, "").trim();
  if (teacherName) {
    const lastName = teacherName.split(/\s+/).pop()?.toUpperCase() ?? "";
    for (const u of users) {
      if (u.profile === "Teacher" && lastName && u.displayName.toUpperCase().includes(lastName)) {
        recipients.push(u.id);
        console.log("[nōto] Found teacher:", u.displayName);
      }
    }
  }

  // Director
  for (const u of users) {
    if (u.displayName.toLowerCase().includes("direct") || u.displayName.toLowerCase().includes("princip")) {
      recipients.push(u.id);
      console.log("[nōto] Found director:", u.displayName);
    }
  }

  // Fallback: school-wide teacher group
  if (recipients.length === 0) {
    for (const g of groups) {
      if (g.name.includes("Enseignants")) {
        recipients.push(g.id);
        console.log("[nōto] Fallback:", g.name);
        break;
      }
    }
  }

  return [...new Set(recipients)];
}

/**
 * Dry-run: find recipients and return their names (for dev/testing).
 */
export async function findRecipientsOnly(
  creds: ConversationCredentials,
  child: Child
): Promise<string[]> {
  await ensureLogin(creds);

  const res = await fetch(`${creds.apiBaseUrl}/conversation/visible`, {
    headers: { Accept: "application/json" },
  });

  if (!res.ok) return ["(impossible de charger les destinataires)"];

  const data = await res.json() as {
    groups?: Array<{ id: string; name: string }>;
    users?: Array<{ id: string; displayName: string; profile?: string }>;
  };

  const groups = data.groups ?? [];
  const users = data.users ?? [];
  const names: string[] = [];

  const classParts = child.className.split(" - ");
  const classShort = classParts.length > 2
    ? classParts.slice(0, -1).join(" - ").trim()
    : classParts[0]?.trim() ?? "";

  // Teacher group
  for (const g of groups) {
    if (g.name.includes("Enseignants") && classShort && g.name.includes(classShort)) {
      names.push(`👥 ${g.name}`);
    }
  }

  // Individual teacher
  const teacherName = classParts[classParts.length - 1]?.replace(/^(M\.|Mme|M)\s*/i, "").trim();
  if (teacherName) {
    const lastName = teacherName.split(/\s+/).pop()?.toUpperCase() ?? "";
    for (const u of users) {
      if (u.profile === "Teacher" && lastName && u.displayName.toUpperCase().includes(lastName)) {
        names.push(`👤 ${u.displayName} (enseignant)`);
      }
    }
  }

  // Director
  for (const u of users) {
    if (u.displayName.toLowerCase().includes("direct") || u.displayName.toLowerCase().includes("princip")) {
      names.push(`👤 ${u.displayName} (direction)`);
    }
  }

  if (names.length === 0) {
    // Fallback
    for (const g of groups) {
      if (g.name.includes("Enseignants")) {
        names.push(`👥 ${g.name} (fallback)`);
        break;
      }
    }
  }

  return names.length > 0 ? names : ["Aucun destinataire trouvé"];
}

export async function sendAbsenceNotification(
  creds: ConversationCredentials,
  req: AbsenceRequest
): Promise<void> {
  // Ensure fresh session
  await ensureLogin(creds);

  // Find recipients
  const recipients = await findRecipients(creds, req.child);
  if (recipients.length === 0) {
    throw new Error("Aucun destinataire trouvé. Vérifiez la classe de l'enfant.");
  }

  console.log("[nōto] Sending absence to", recipients.length, "recipients:", recipients);

  const subject = buildSubject(req.child, req.date);
  const body = buildBody(req);

  // Create draft
  const draftRes = await fetch(`${creds.apiBaseUrl}/conversation/draft`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ subject, body, to: recipients, cc: [], bcc: [] }),
  });

  console.log("[nōto] Draft response:", draftRes.status);

  if (!draftRes.ok) {
    const err = await draftRes.text();
    console.warn("[nōto] Draft error:", err.substring(0, 100));
    throw new Error(`Erreur création brouillon (${draftRes.status})`);
  }

  const draft = await draftRes.json() as { id: string };
  console.log("[nōto] Draft created:", draft.id);

  // Send
  const sendRes = await fetch(`${creds.apiBaseUrl}/conversation/send?id=${draft.id}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ subject, body, to: recipients, cc: [], bcc: [] }),
  });

  console.log("[nōto] Send response:", sendRes.status);

  if (!sendRes.ok) {
    const err = await sendRes.text();
    console.warn("[nōto] Send error:", err.substring(0, 100));
    throw new Error(`Erreur envoi (${sendRes.status})`);
  }

  console.log("[nōto] Absence sent successfully!");
}
