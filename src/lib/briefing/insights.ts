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

  // Grade trend (compare last 5 vs previous 5, weighted on /20)
  if (grades.length >= 5) {
    const recent = grades.slice(0, 5);
    const older = grades.slice(5, 10);
    if (older.length >= 3) {
      const avgOn20 = (list: Grade[]) => {
        let w = 0, c = 0;
        for (const g of list) { if (g.outOf > 0) { w += to20(g.value, g.outOf) * g.coefficient; c += g.coefficient; } }
        return c > 0 ? w / c : 0;
      };
      const diff = avgOn20(recent) - avgOn20(older);
      if (diff > 1) {
        insights.push({
          label: "Tendance",
          text: `Les notes de votre enfant sont en hausse (+${diff.toFixed(1)} pts/20). À encourager !`,
          accent: "green",
        });
      } else if (diff < -1) {
        insights.push({
          label: "Tendance",
          text: `Les notes récentes sont en baisse (${diff.toFixed(1)} pts/20). Un échange avec votre enfant peut aider.`,
          accent: "red",
        });
      }
    }
  }

  // Best and weakest subjects (weighted on /20)
  if (grades.length >= 3) {
    const bySubject = new Map<string, { weighted: number; coeff: number }>();
    for (const g of grades) {
      if (g.outOf <= 0) continue;
      const prev = bySubject.get(g.subject) ?? { weighted: 0, coeff: 0 };
      prev.weighted += to20(g.value, g.outOf) * g.coefficient;
      prev.coeff += g.coefficient;
      bySubject.set(g.subject, prev);
    }
    const averages = [...bySubject.entries()]
      .filter(([, v]) => v.coeff > 0)
      .map(([subject, v]) => ({ subject, avg20: v.weighted / v.coeff }))
      .sort((a, b) => b.avg20 - a.avg20);

    if (averages.length >= 2) {
      const best = averages[0]!;
      if (best.avg20 >= 14) {
        insights.push({
          label: "Point fort",
          text: `${best.subject} est la matière la plus solide (${best.avg20.toFixed(1)}/20).`,
          accent: "green",
        });
      }
      const weakest = averages[averages.length - 1]!;
      if (weakest.avg20 < 10) {
        insights.push({
          label: "À surveiller",
          text: `${weakest.subject} a la moyenne la plus basse (${weakest.avg20.toFixed(1)}/20).`,
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
      text: `${pending.length} devoirs en attente — pensez à vérifier avec votre enfant.`,
      accent: "amber",
    });
  }

  // Cancelled classes
  const cancelled = schedule.filter((s) => s.isCancelled);
  if (cancelled.length >= 2) {
    insights.push({
      label: "Emploi du temps",
      text: `${cancelled.length} cours annulés aujourd'hui. Votre enfant sortira plus tôt.`,
      accent: "amber",
    });
  }

  return insights;
}

export function extractEntTextInsights(
  schoolbookWords: SchoolbookWord[],
  unreadMessages: number,
  childFirstName?: string,
): TextInsight[] {
  const insights: TextInsight[] = [];

  // Summarize schoolbook content — focus on what matters for THIS child
  for (const w of schoolbookWords.slice(0, 3)) {
    const plain = stripHtml(w.text).replace(/\s+/g, " ").trim();
    if (plain.length > 20) {
      // Extract key info: dates, actions required
      const hasDate = plain.match(/\d{1,2}\s+(janvier|février|mars|avril|mai|juin|juillet|août|septembre|octobre|novembre|décembre)/i);
      const hasAction = /inscription|répondre|retourner|signer|remplir|apporter/i.test(plain);

      insights.push({
        label: hasAction ? "Action requise" : w.sender || "Carnet",
        text: plain.slice(0, 150) + (plain.length > 150 ? "…" : ""),
        accent: hasAction ? "red" : "default",
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
  average: number; // 0-1 for bar rendering
  average20: number; // on /20 for display
  classAverage?: number; // 0-1
  classAverage20?: number; // on /20
  gradeCount: number;
}

export interface StatsData {
  /** Overall average as percentage */
  overallAverage?: StatItem;
  /** Per-subject averages for bar chart */
  subjects: SubjectStat[];
  /** Quick counters */
  counters: Array<{ label: string; value: number }>;
}

/** Normalize a grade to /20, weighted by coefficient */
function to20(value: number, outOf: number): number {
  if (outOf <= 0) return 0;
  return (value / outOf) * 20;
}

export function extractStats(
  grades: Grade[],
  schedule: ScheduleEntry[],
  homework: Homework[],
): StatsData {
  const subjects: SubjectStat[] = [];
  const bySubject = new Map<string, {
    values: number[]; outOfs: number[]; coeffs: number[];
    classAvgs: number[];
  }>();

  for (const g of grades) {
    if (g.outOf <= 0) continue;
    const prev = bySubject.get(g.subject) ?? { values: [], outOfs: [], coeffs: [], classAvgs: [] };
    prev.values.push(g.value);
    prev.outOfs.push(g.outOf);
    prev.coeffs.push(g.coefficient);
    if (g.classAverage !== undefined) prev.classAvgs.push(g.classAverage);
    bySubject.set(g.subject, prev);
  }

  // Weighted averages on /20
  let totalWeighted = 0;
  let totalCoeff = 0;

  for (const [subject, data] of bySubject) {
    // Weighted average for this subject on /20
    let subWeighted = 0;
    let subCoeff = 0;
    for (let i = 0; i < data.values.length; i++) {
      const on20 = to20(data.values[i]!, data.outOfs[i]!);
      subWeighted += on20 * data.coeffs[i]!;
      subCoeff += data.coeffs[i]!;
    }
    const avg20 = subCoeff > 0 ? subWeighted / subCoeff : 0;

    // Class average on /20
    let classAvg20: number | undefined;
    if (data.classAvgs.length > 0) {
      let cWeighted = 0;
      let cCoeff = 0;
      for (let i = 0; i < data.classAvgs.length; i++) {
        cWeighted += to20(data.classAvgs[i]!, data.outOfs[i]!) * data.coeffs[i]!;
        cCoeff += data.coeffs[i]!;
      }
      classAvg20 = cCoeff > 0 ? cWeighted / cCoeff : undefined;
    }

    subjects.push({
      subject,
      average: avg20 / 20, // 0-1 for bar rendering
      average20: avg20,
      classAverage: classAvg20 !== undefined ? classAvg20 / 20 : undefined,
      classAverage20: classAvg20,
      gradeCount: data.values.length,
    });

    totalWeighted += subWeighted;
    totalCoeff += subCoeff;
  }

  subjects.sort((a, b) => b.average - a.average);

  const overall20 = totalCoeff > 0 ? totalWeighted / totalCoeff : undefined;
  const overallAverage: StatItem | undefined = overall20 !== undefined
    ? {
        label: "Moyenne générale",
        value: Math.round(overall20 * 10) / 10,
        maxValue: 20,
        unit: "/20",
        accent: overall20 >= 12 ? "green" : overall20 >= 10 ? "amber" : "red",
      }
    : undefined;

  const active = schedule.filter((s) => !s.isCancelled);
  const pending = homework.filter((h) => !h.isDone);

  const counters = [
    { label: "Cours", value: active.length },
    { label: "Devoirs", value: pending.length },
    { label: "Notes", value: grades.length },
  ];

  return { overallAverage, subjects, counters };
}

export function extractEntStats(
  schoolbookWords: SchoolbookWord[],
  unreadMessages: number,
  blogCount: number,
): StatsData {
  const counters = [
    { label: "Carnet", value: schoolbookWords.length },
    { label: "Messages", value: unreadMessages },
    { label: "Blog", value: blogCount },
  ];

  return { subjects: [], counters };
}
