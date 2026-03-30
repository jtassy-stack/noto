/**
 * Smart French text generator for school briefings.
 * Produces natural-sounding summaries from structured briefing data.
 * Works everywhere — no ML, no download, instant.
 *
 * Phase 2: Apple FoundationModels (iOS 26+) replaces this when available.
 * Phase 3: ExecuTorch for long-form summarization (carnet de liaison content).
 */

import type { Briefing, BriefingItem } from "./engine";

// --- Sentence fragments (randomized for variety) ---

const OPENERS = [
  "Voici l'essentiel.",
  "En résumé :",
  "Le point du jour :",
  "À retenir :",
];

const SCHEDULE_PHRASES = [
  (n: number, first: string, time: string) =>
    `Votre enfant a ${n} cours aujourd'hui, ça commence par ${first} à ${time}.`,
  (n: number, first: string, time: string) =>
    `Journée de ${n} cours — début à ${time} avec ${first}.`,
  (n: number, first: string, time: string) =>
    `${n} cours au programme aujourd'hui, ${first} à ${time} en premier.`,
];

const NO_CLASS_PHRASES = [
  "Votre enfant n'a pas cours aujourd'hui.",
  "Pas de cours prévu aujourd'hui.",
  "Journée sans cours.",
];

const CANCELLED_PHRASES = [
  (n: number, subjects: string) => `${n} cours annulé${n > 1 ? "s" : ""} (${subjects}).`,
  (n: number, subjects: string) => `À noter : ${subjects} annulé${n > 1 ? "s" : ""}.`,
];

const URGENT_HW_PHRASES = [
  (n: number, subjects: string) => `${n} devoir${n > 1 ? "s" : ""} à vérifier ce soir : ${subjects}.`,
  (n: number, subjects: string) => `Pensez à vérifier : ${subjects} (${n > 1 ? "à rendre bientôt" : "pour bientôt"}).`,
];

const UPCOMING_HW_PHRASES = [
  (n: number) => `${n} devoir${n > 1 ? "s" : ""} à suivre cette semaine.`,
  (n: number) => `${n} devoir${n > 1 ? "s" : ""} à venir dans la semaine.`,
];

const GRADE_GOOD_PHRASES = [
  (subject: string, value: string) => `Bonne note en ${subject} : ${value} — à encourager !`,
  (subject: string, value: string) => `${value} en ${subject}, bon travail.`,
];

const GRADE_ALERT_PHRASES = [
  (subject: string, value: string) => `Note à surveiller en ${subject} : ${value}.`,
  (subject: string, value: string) => `${value} en ${subject} — un échange avec votre enfant peut aider.`,
];

const SCHOOLBOOK_PHRASES = [
  (n: number, sender: string) => `${n} mot${n > 1 ? "s" : ""} au carnet de liaison de ${sender}.`,
  (n: number, sender: string) => `Carnet de liaison : ${n} nouveau${n > 1 ? "x" : ""} mot${n > 1 ? "s" : ""} de ${sender}.`,
];

const UNREAD_MSG_PHRASES = [
  (n: number) => `${n} message${n > 1 ? "s" : ""} non lu${n > 1 ? "s" : ""}.`,
  (n: number) => `${n} message${n > 1 ? "s" : ""} en attente.`,
];

const BLOG_PHRASES = [
  (n: number) => `${n} nouveau${n > 1 ? "x" : ""} billet${n > 1 ? "s" : ""} sur le blog.`,
];

const DOCUMENT_PHRASES = [
  (n: number) => `${n} document${n > 1 ? "s" : ""} à consulter dans le carnet.`,
  (n: number) => `${n} pièce${n > 1 ? "s" : ""} jointe${n > 1 ? "s" : ""} à regarder.`,
];

// --- Helpers ---

function pick<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)]!;
}

// --- Main generator ---

export function generateTextSummary(briefing: Briefing): string {
  const parts: string[] = [];
  const items = briefing.items;

  // Schedule
  const scheduleItems = items.filter((i) => i.type === "schedule_today");
  const noClass = items.find((i) => i.type === "no_class");
  const cancelledItems = items.filter(
    (i) => i.type === "schedule_today" && i.accent === "amber"
  );

  if (noClass) {
    parts.push(pick(NO_CLASS_PHRASES));
  } else if (scheduleItems.length > 0) {
    const main = scheduleItems.find((i) => i.accent !== "amber");
    if (main) {
      // Extract count and first class from title/subtitle
      const countMatch = main.title.match(/^(\d+)/);
      const count = countMatch ? parseInt(countMatch[1]!) : 0;
      const timeMatch = main.subtitle?.match(/à (\d{2}:\d{2})/);
      const time = timeMatch ? timeMatch[1]! : "";
      const subjectMatch = main.subtitle?.match(/: (.+?) à/);
      const subject = subjectMatch ? subjectMatch[1]! : "";

      if (count > 0 && subject && time) {
        parts.push(pick(SCHEDULE_PHRASES)(count, subject, time));
      }
    }
  }

  if (cancelledItems.length > 0) {
    const subjects = cancelledItems.map((i) => i.subtitle).filter(Boolean).join(", ");
    if (subjects) {
      parts.push(pick(CANCELLED_PHRASES)(cancelledItems.length, subjects));
    }
  }

  // Homework
  const urgentHw = items.filter((i) => i.type === "homework_urgent");
  const upcomingHw = items.find((i) => i.type === "homework_upcoming");

  if (urgentHw.length > 0) {
    const subjects = urgentHw.map((i) => i.title).join(", ");
    parts.push(pick(URGENT_HW_PHRASES)(urgentHw.length, subjects));
  }

  if (upcomingHw) {
    const countMatch = upcomingHw.title.match(/^(\d+)/);
    const count = countMatch ? parseInt(countMatch[1]!) : 0;
    if (count > 0) parts.push(pick(UPCOMING_HW_PHRASES)(count));
  }

  // Grades
  const goodGrades = items.filter((i) => i.type === "grade_good");
  const alertGrades = items.filter((i) => i.type === "grade_alert");

  if (goodGrades.length > 0) {
    const g = goodGrades[0]!;
    parts.push(pick(GRADE_GOOD_PHRASES)(g.title, g.value ?? ""));
  }
  if (alertGrades.length > 0) {
    const g = alertGrades[0]!;
    parts.push(pick(GRADE_ALERT_PHRASES)(g.title, g.value ?? ""));
  }

  // Schoolbook (ENT)
  const schoolbook = items.filter((i) => i.type === "schoolbook_urgent");
  if (schoolbook.length > 0) {
    const senders = [...new Set(schoolbook.map((i) => i.subtitle?.split(" · ")[0]).filter(Boolean))];
    parts.push(pick(SCHOOLBOOK_PHRASES)(schoolbook.length, senders.join(", ") || "l'école"));
  }

  // Messages
  const unreadMsg = items.find((i) => i.type === "messages_unread");
  if (unreadMsg) {
    const countMatch = unreadMsg.title.match(/^(\d+)/);
    const count = countMatch ? parseInt(countMatch[1]!) : 0;
    if (count > 0) parts.push(pick(UNREAD_MSG_PHRASES)(count));
  }

  // Blog
  const blogs = items.filter((i) => i.type === "timeline" && i.accent === "green");
  if (blogs.length > 0) {
    parts.push(pick(BLOG_PHRASES)(blogs.length));
  }

  // Documents
  const docCount = items
    .filter((i) => i.subtitle?.includes("pièce"))
    .reduce((sum, i) => {
      const m = i.subtitle?.match(/(\d+) pièce/);
      return sum + (m ? parseInt(m[1]!) : 0);
    }, 0);
  if (docCount > 0) {
    parts.push(pick(DOCUMENT_PHRASES)(docCount));
  }

  if (parts.length === 0) return "";
  return parts.join(" ");
}
