/**
 * Pronote client — wraps Pawnote.js for parent account access.
 *
 * TODO (Phase 1, Sprint 2):
 * - npm install pawnote
 * - Implement authenticateParent() using Pawnote's parent login flow
 * - Fetch children list, grades, schedule, homework, absences
 * - Map Pawnote types → nōto types (see @/types)
 *
 * Pawnote repo: https://github.com/LiterateInk/Pawnote.js (MIT)
 */

import type { Account, Child, Grade, ScheduleEntry, Homework } from "@/types";

export interface PronoteSession {
  accountId: string;
  // Pawnote session object will go here
}

export async function authenticate(
  _instanceUrl: string,
  _username: string,
  _password: string
): Promise<PronoteSession> {
  throw new Error("Pronote authentication not yet implemented — install pawnote first");
}

export async function fetchChildren(_session: PronoteSession): Promise<Child[]> {
  throw new Error("Not implemented");
}

export async function fetchGrades(
  _session: PronoteSession,
  _childId: string
): Promise<Grade[]> {
  throw new Error("Not implemented");
}

export async function fetchSchedule(
  _session: PronoteSession,
  _childId: string,
  _dateFrom: string,
  _dateTo: string
): Promise<ScheduleEntry[]> {
  throw new Error("Not implemented");
}

export async function fetchHomework(
  _session: PronoteSession,
  _childId: string
): Promise<Homework[]> {
  throw new Error("Not implemented");
}
