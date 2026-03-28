/**
 * ÉcoleDirecte client — custom wrapper for the unofficial API.
 *
 * TODO (Phase 2, Sprint 4):
 * - Implement REST client for api.ecoledirecte.com/v3
 * - Authentication via /login endpoint
 * - Fetch children, grades, schedule, homework
 * - Map API response → nōto types (see @/types)
 *
 * API docs (community): https://github.com/EduWireApps/ecoledirecte-api-docs
 */

import type { Account, Child, Grade, ScheduleEntry, Homework } from "@/types";

export async function authenticate(
  _username: string,
  _password: string
): Promise<{ accountId: string; token: string }> {
  throw new Error("ÉcoleDirecte authentication not yet implemented");
}

export async function fetchChildren(_token: string): Promise<Child[]> {
  throw new Error("Not implemented");
}

export async function fetchGrades(
  _token: string,
  _childId: string
): Promise<Grade[]> {
  throw new Error("Not implemented");
}

export async function fetchSchedule(
  _token: string,
  _childId: string,
  _dateFrom: string,
  _dateTo: string
): Promise<ScheduleEntry[]> {
  throw new Error("Not implemented");
}

export async function fetchHomework(
  _token: string,
  _childId: string
): Promise<Homework[]> {
  throw new Error("Not implemented");
}
