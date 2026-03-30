/**
 * Extract parent-friendly insights and numerical stats from school data.
 * Text insights = things parents care about, phrased naturally.
 * Stats = numerical data ready for visual rendering.
 */

import type { Grade, ScheduleEntry, Homework } from "@/types";
import type { SchoolbookWord } from "./engine";
import { stripHtml } from "@/lib/utils/html";

// --- Text Insights ---

export interface TextInsight {
  label: string;
  text: string;
  accent: "green" | "red" | "amber" | "default";
}

export function extractTextInsights(
  grades: Grade[],
  schedule: ScheduleEntry[],
  homework: Homework[],
): TextInsight[] {
  const insights: TextInsight[] = [];

  // Grade trend (compare last 5 vs previous 5)
  if (grades.length >= 5) {
    const recent = grades.slice(0, 5);
    const older = grades.slice(5, 10);
    if (older.length >= 3) {
      const recentAvg = recent.reduce((s, g) => s + (g.outOf > 0 ? g.value / g.outOf : 0), 0) / recent.length;
      const olderAvg = older.reduce((s, g) => s + (g.outOf > 0 ? g.value / g.outOf : 0), 0) / older.length;
      const diff = recentAvg - olderAvg;
      if (diff > 0.05) {
        insights.push({
          label: "Tendance",
          text: "Les notes récentes sont en hausse par rapport aux précédentes.",
          accent: "green",
        });
      } else if (diff < -0.05) {
        insights.push({
          label: "Tendance",
          text: "Les notes récentes sont en baisse. Un point avec l'enfant peut être utile.",
          accent: "red",
        });
      }
    }
  }

  // Best and weakest subjects
  if (grades.length >= 3) {
    const bySubject = new Map<string, { total: number; count: number }>();
    for (const g of grades) {
      if (g.outOf <= 0) continue;
      const prev = bySubject.get(g.subject) ?? { total: 0, count: 0 };
      prev.total += g.value / g.outOf;
      prev.count += 1;
      bySubject.set(g.subject, prev);
    }
    const averages = [...bySubject.entries()]
      .filter(([, v]) => v.count >= 2)
      .map(([subject, v]) => ({ subject, avg: v.total / v.count }))
      .sort((a, b) => b.avg - a.avg);

    if (averages.length >= 2) {
      const best = averages[0]!;
      if (best.avg >= 0.7) {
        insights.push({
          label: "Point fort",
          text: `${best.subject} est la matière la plus solide (${Math.round(best.avg * 100)}%).`,
          accent: "green",
        });
      }
      const weakest = averages[averages.length - 1]!;
      if (weakest.avg < 0.5) {
        insights.push({
          label: "À surveiller",
          text: `${weakest.subject} a la moyenne la plus basse (${Math.round(weakest.avg * 100)}%).`,
          accent: "amber",
        });
      }
    }
  }

  // Homework load
  const pending = homework.filter((h) => !h.isDone);
  if (pending.length >= 5) {
    insights.push({
      label: "Charge de travail",
      text: `${pending.length} devoirs en attente — semaine chargée.`,
      accent: "amber",
    });
  }

  // Cancelled classes
  const cancelled = schedule.filter((s) => s.isCancelled);
  if (cancelled.length >= 2) {
    insights.push({
      label: "Emploi du temps",
      text: `${cancelled.length} cours annulés aujourd'hui.`,
      accent: "amber",
    });
  }

  return insights;
}

export function extractEntTextInsights(
  schoolbookWords: SchoolbookWord[],
  unreadMessages: number,
): TextInsight[] {
  const insights: TextInsight[] = [];

  // Summarize schoolbook content
  for (const w of schoolbookWords.slice(0, 2)) {
    const plain = stripHtml(w.text).replace(/\s+/g, " ").trim();
    if (plain.length > 20) {
      insights.push({
        label: w.sender || "Carnet",
        text: plain.slice(0, 150) + (plain.length > 150 ? "…" : ""),
        accent: "default",
      });
    }
  }

  if (unreadMessages > 5) {
    insights.push({
      label: "Messagerie",
      text: `${unreadMessages} messages en attente de lecture.`,
      accent: "amber",
    });
  }

  return insights;
}

// --- Numerical Stats ---

export interface StatItem {
  label: string;
  value: number;
  maxValue: number;
  unit: string;
  accent: "green" | "red" | "amber" | "default";
}

export interface SubjectStat {
  subject: string;
  average: number; // 0-1
  classAverage?: number; // 0-1
  gradeCount: number;
}

export interface StatsData {
  /** Overall average as percentage */
  overallAverage?: StatItem;
  /** Per-subject averages for bar chart */
  subjects: SubjectStat[];
  /** Quick counters */
  counters: Array<{ label: string; value: number; icon: string }>;
}

export function extractStats(
  grades: Grade[],
  schedule: ScheduleEntry[],
  homework: Homework[],
): StatsData {
  const subjects: SubjectStat[] = [];
  const bySubject = new Map<string, { values: number[]; classAvgs: number[]; outOfs: number[] }>();

  for (const g of grades) {
    if (g.outOf <= 0) continue;
    const prev = bySubject.get(g.subject) ?? { values: [], classAvgs: [], outOfs: [] };
    prev.values.push(g.value);
    prev.outOfs.push(g.outOf);
    if (g.classAverage !== undefined) prev.classAvgs.push(g.classAverage);
    bySubject.set(g.subject, prev);
  }

  let totalPct = 0;
  let totalCount = 0;

  for (const [subject, data] of bySubject) {
    const avg = data.values.reduce((s, v, i) => s + v / data.outOfs[i]!, 0) / data.values.length;
    const classAvg = data.classAvgs.length > 0
      ? data.classAvgs.reduce((s, v, i) => s + v / data.outOfs[i]!, 0) / data.classAvgs.length
      : undefined;

    subjects.push({ subject, average: avg, classAverage: classAvg, gradeCount: data.values.length });
    totalPct += avg;
    totalCount++;
  }

  subjects.sort((a, b) => b.average - a.average);

  const overallPct = totalCount > 0 ? totalPct / totalCount : undefined;
  const overallAverage: StatItem | undefined = overallPct !== undefined
    ? {
        label: "Moyenne générale",
        value: Math.round(overallPct * 100),
        maxValue: 100,
        unit: "%",
        accent: overallPct >= 0.6 ? "green" : overallPct >= 0.5 ? "amber" : "red",
      }
    : undefined;

  const active = schedule.filter((s) => !s.isCancelled);
  const pending = homework.filter((h) => !h.isDone);

  const counters = [
    { label: "Cours", value: active.length, icon: "📚" },
    { label: "Devoirs", value: pending.length, icon: "📝" },
    { label: "Notes", value: grades.length, icon: "📊" },
  ];

  return { overallAverage, subjects, counters };
}

export function extractEntStats(
  schoolbookWords: SchoolbookWord[],
  unreadMessages: number,
  blogCount: number,
): StatsData {
  const counters = [
    { label: "Carnet", value: schoolbookWords.length, icon: "📋" },
    { label: "Messages", value: unreadMessages, icon: "✉️" },
    { label: "Blog", value: blogCount, icon: "📝" },
  ];

  return { subjects: [], counters };
}
