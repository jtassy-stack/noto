/**
 * Briefing Engine — collects and prioritizes child data into a structured daily context.
 *
 * Phase 1: Pure logic, rule-based scoring.
 * Phase 2: Feed this structured context to Apple FoundationModels (CoreML)
 *          via a Swift native module for natural language summaries.
 */

import type { Grade, ScheduleEntry, Homework } from "@/types";

// --- Briefing item types ---

export type BriefingItemType =
  | "schedule_today"
  | "homework_urgent"
  | "homework_upcoming"
  | "grade_new"
  | "grade_alert"
  | "grade_good"
  | "no_class"
  | "timeline"
  | "schoolbook_urgent"
  | "schoolbook_ok"
  | "messages_unread";

export interface BriefingItem {
  type: BriefingItemType;
  priority: number; // 0-100, higher = more important
  title: string;
  subtitle?: string;
  value?: string;
  accent?: "green" | "red" | "amber" | "default";
  data?: unknown; // original data for Phase 2 LLM context
}

export interface Briefing {
  greeting: string;
  items: BriefingItem[];
  /** Structured context for Phase 2 LLM summarization */
  llmContext: string;
}

// --- Helpers ---

function daysUntil(dateStr: string): number {
  const now = new Date();
  now.setHours(0, 0, 0, 0);
  const target = new Date(dateStr);
  target.setHours(0, 0, 0, 0);
  return Math.round((target.getTime() - now.getTime()) / 86400000);
}

function gradeQuality(value: number, outOf: number): "good" | "ok" | "alert" {
  const pct = outOf > 0 ? value / outOf : 0;
  if (pct >= 0.7) return "good";
  if (pct >= 0.5) return "ok";
  return "alert";
}

function timeGreeting(): string {
  const h = new Date().getHours();
  if (h < 12) return "Bonjour";
  if (h < 18) return "Bon après-midi";
  return "Bonsoir";
}

// --- Main engine ---

export function buildBriefing(
  childFirstName: string,
  grades: Grade[],
  schedule: ScheduleEntry[],
  homework: Homework[],
): Briefing {
  const items: BriefingItem[] = [];
  const contextParts: string[] = [];

  // --- Schedule ---
  const activeClasses = schedule.filter((s) => !s.isCancelled);
  const cancelledClasses = schedule.filter((s) => s.isCancelled);

  if (activeClasses.length > 0) {
    const firstClass = activeClasses[0]!;
    const startTime = new Date(firstClass.startTime).toLocaleTimeString("fr-FR", {
      hour: "2-digit", minute: "2-digit",
    });
    const subjects = activeClasses.map((s) => s.subject);
    const uniqueSubjects = [...new Set(subjects)];

    items.push({
      type: "schedule_today",
      priority: 90,
      title: `${activeClasses.length} cours aujourd'hui`,
      subtitle: `Premier cours : ${firstClass.subject} à ${startTime}`,
      accent: "default",
      data: activeClasses,
    });
    contextParts.push(
      `Aujourd'hui: ${activeClasses.length} cours (${uniqueSubjects.join(", ")}), début à ${startTime}.`
    );
  } else {
    items.push({
      type: "no_class",
      priority: 80,
      title: "Pas de cours aujourd'hui",
      accent: "green",
    });
    contextParts.push("Pas de cours aujourd'hui.");
  }

  if (cancelledClasses.length > 0) {
    const names = cancelledClasses.map((c) => c.subject).join(", ");
    items.push({
      type: "schedule_today",
      priority: 75,
      title: `${cancelledClasses.length} cours annulé${cancelledClasses.length > 1 ? "s" : ""}`,
      subtitle: names,
      accent: "amber",
    });
    contextParts.push(`Cours annulés: ${names}.`);
  }

  // --- Homework ---
  const pendingHomework = homework.filter((h) => !h.isDone);
  const urgentHw = pendingHomework.filter((h) => {
    const d = daysUntil(h.dueDate);
    return d >= 0 && d <= 1;
  });
  const upcomingHw = pendingHomework.filter((h) => {
    const d = daysUntil(h.dueDate);
    return d > 1 && d <= 7;
  });

  if (urgentHw.length > 0) {
    for (const h of urgentHw) {
      const d = daysUntil(h.dueDate);
      items.push({
        type: "homework_urgent",
        priority: 95,
        title: h.subject,
        subtitle: h.description.slice(0, 80),
        value: d === 0 ? "Aujourd'hui" : "Demain",
        accent: "red",
        data: h,
      });
    }
    contextParts.push(
      `Devoirs urgents: ${urgentHw.map((h) => `${h.subject} (${daysUntil(h.dueDate) === 0 ? "aujourd'hui" : "demain"})`).join(", ")}.`
    );
  }

  if (upcomingHw.length > 0) {
    items.push({
      type: "homework_upcoming",
      priority: 50,
      title: `${upcomingHw.length} devoir${upcomingHw.length > 1 ? "s" : ""} cette semaine`,
      subtitle: upcomingHw.map((h) => h.subject).join(", "),
      accent: "default",
    });
    contextParts.push(
      `${upcomingHw.length} devoirs cette semaine: ${upcomingHw.map((h) => h.subject).join(", ")}.`
    );
  }

  // --- Grades ---
  const recentGrades = grades.slice(0, 5); // already sorted by date DESC
  const weekOldCutoff = new Date();
  weekOldCutoff.setDate(weekOldCutoff.getDate() - 7);

  const newGrades = recentGrades.filter(
    (g) => new Date(g.date) >= weekOldCutoff
  );

  for (const g of newGrades) {
    const quality = gradeQuality(g.value, g.outOf);
    const isAlert = quality === "alert";
    const isGood = quality === "good";

    items.push({
      type: isAlert ? "grade_alert" : isGood ? "grade_good" : "grade_new",
      priority: isAlert ? 70 : isGood ? 60 : 55,
      title: g.subject,
      value: `${g.value}/${g.outOf}`,
      subtitle: g.classAverage !== undefined
        ? `Moyenne classe : ${g.classAverage}/${g.outOf}`
        : undefined,
      accent: isAlert ? "red" : isGood ? "green" : "default",
      data: g,
    });
  }

  if (newGrades.length > 0) {
    contextParts.push(
      `Notes récentes: ${newGrades.map((g) => `${g.subject} ${g.value}/${g.outOf}`).join(", ")}.`
    );
  }

  // Sort by priority
  items.sort((a, b) => b.priority - a.priority);

  const greeting = `${timeGreeting()} ! Voici le point pour ${childFirstName}.`;

  return {
    greeting,
    items,
    llmContext: `Élève: ${childFirstName}.\n${contextParts.join("\n")}`,
  };
}

// --- ENT briefing (schoolbook + messages + timeline) ---

export interface TimelineEntry {
  id: string;
  type: string;
  eventType: string;
  message: string;
  date?: string;
  sender?: string;
  resourceUri?: string;
}

export interface SchoolbookWord {
  id: string;
  title: string;
  text: string;
  sender: string;
  date: string;
}

export interface EntBriefingData {
  timeline: TimelineEntry[];
  unreadMessages: number;
  recentMessages: Array<{ from: string; subject: string; date: string }>;
  schoolbookWords?: SchoolbookWord[];
}

export function buildEntBriefing(
  childFirstName: string,
  data: EntBriefingData,
): Briefing {
  const items: BriefingItem[] = [];
  const contextParts: string[] = [];

  // Categorize timeline entries
  const schoolbookEntries = data.timeline.filter((n) => n.type === "SCHOOLBOOK");
  const messageEntries = data.timeline.filter((n) => n.type === "MESSAGERIE");
  const blogEntries = data.timeline.filter((n) => n.type === "BLOG");
  const otherEntries = data.timeline.filter(
    (n) => n.type !== "SCHOOLBOOK" && n.type !== "MESSAGERIE" && n.type !== "BLOG" && n.type !== "ARCHIVE"
  );

  // --- Carnet de liaison (SCHOOLBOOK) — highest priority ---
  // Use full schoolbook words if available, fallback to timeline entries
  const words = data.schoolbookWords ?? [];
  const allDocuments: string[] = [];

  if (words.length > 0) {
    for (const w of words) {
      const dateStr = formatEntDate(w.date);
      const docs = extractDocuments(w.text);
      allDocuments.push(...docs);

      items.push({
        type: "schoolbook_urgent",
        priority: 95,
        title: w.title,
        subtitle: [w.sender, dateStr, docs.length > 0 ? `${docs.length} pièce(s) jointe(s)` : ""].filter(Boolean).join(" · "),
        accent: "red",
        data: { ...w, type: "SCHOOLBOOK", wordId: String(w.id), wordTitle: w.title },
      });
    }

    // Rich LLM context with document names and word summaries
    const wordSummaries = words.map((w) => {
      const plainText = w.text.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
      const docs = extractDocuments(w.text);
      const docStr = docs.length > 0 ? ` [Documents joints: ${docs.join(", ")}]` : "";
      return `- "${w.title}" de ${w.sender}: ${plainText.slice(0, 200)}${docStr}`;
    });
    contextParts.push(`Carnet de liaison (${words.length} mot(s)):\n${wordSummaries.join("\n")}`);
  } else if (schoolbookEntries.length > 0) {
    // Fallback: timeline-only schoolbook entries
    for (const w of schoolbookEntries) {
      const dateStr = formatEntDate(w.date);
      const title = (w as unknown as { wordTitle?: string }).wordTitle
        ?? w.message.match(/a publié le mot\s+(.+)/i)?.[1]?.trim()
        ?? w.message.slice(0, 80);

      items.push({
        type: "schoolbook_urgent",
        priority: 95,
        title,
        subtitle: [w.sender, dateStr].filter(Boolean).join(" · "),
        accent: "red",
        data: w,
      });
    }
    contextParts.push(
      `Carnet de liaison: ${schoolbookEntries.length} mot(s) de ${[...new Set(schoolbookEntries.map((w) => w.sender).filter(Boolean))].join(", ")}.`
    );
  }

  // Documents summary
  if (allDocuments.length > 0) {
    contextParts.push(`Documents à consulter: ${allDocuments.join(", ")}.`);
  }

  // --- Messages non lus ---
  if (data.unreadMessages > 0) {
    items.push({
      type: "messages_unread",
      priority: 80,
      title: `${data.unreadMessages} message${data.unreadMessages > 1 ? "s" : ""} non lu${data.unreadMessages > 1 ? "s" : ""}`,
      subtitle: data.recentMessages.length > 0
        ? data.recentMessages.slice(0, 2).map((m) => m.from).join(", ")
        : undefined,
      accent: "amber",
    });
    contextParts.push(`${data.unreadMessages} messages non lus.`);
  } else if (messageEntries.length > 0) {
    // Show recent message activity from timeline
    const latestMsg = messageEntries[0]!;
    items.push({
      type: "timeline",
      priority: 55,
      title: latestMsg.message.slice(0, 100),
      subtitle: formatEntDate(latestMsg.date),
      accent: "default",
      data: latestMsg,
    });
  }

  // --- Blog posts ---
  if (blogEntries.length > 0) {
    // Group by blog name if possible, show latest
    const latestBlogs = blogEntries.slice(0, 3);
    for (const b of latestBlogs) {
      const dateStr = formatEntDate(b.date);
      // Extract blog post title: "X a publié un billet TITLE dans le blog BLOG"
      const billetMatch = b.message.match(/a publié un billet\s+(.+?)(?:\s+dans le blog|$)/i);
      const title = billetMatch ? billetMatch[1]!.trim() : b.message.slice(0, 80);

      items.push({
        type: "timeline",
        priority: 45,
        title,
        subtitle: [b.sender, dateStr].filter(Boolean).join(" · "),
        accent: "green",
        data: b,
      });
    }
    if (blogEntries.length > 3) {
      contextParts.push(`${blogEntries.length} billets de blog récents.`);
    }
  }

  // --- Other ---
  for (const n of otherEntries.slice(0, 2)) {
    items.push({
      type: "timeline",
      priority: 30,
      title: n.message.slice(0, 100),
      subtitle: formatEntDate(n.date),
      accent: "default",
      data: n,
    });
  }

  // Sort by priority
  items.sort((a, b) => b.priority - a.priority);

  const hasNews = items.length > 0;
  const greeting = hasNews
    ? `${timeGreeting()} ! Voici le point pour ${childFirstName}.`
    : `${timeGreeting()} ! Rien de nouveau pour ${childFirstName}.`;

  return {
    greeting,
    items,
    llmContext: `Élève: ${childFirstName}.\n${contextParts.join("\n")}`,
  };
}

/** Extract document link names from schoolbook HTML */
function extractDocuments(html: string): string[] {
  const docs: string[] = [];
  const regex = /href="\/workspace\/document\/[^"]*"[^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = regex.exec(html)) !== null) {
    const name = m[1]!.replace(/<[^>]+>/g, "").trim();
    if (name) docs.push(name);
  }
  return docs;
}

function formatEntDate(date?: string): string {
  if (!date) return "";
  try {
    return new Date(date).toLocaleDateString("fr-FR", { day: "numeric", month: "short" });
  } catch {
    return "";
  }
}
