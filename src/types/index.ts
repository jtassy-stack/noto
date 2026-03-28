// --- Provider types ---

export type Provider = "pronote" | "ecoledirecte" | "skolengo";

export interface Account {
  id: string;
  provider: Provider;
  /** Display name (parent name) */
  displayName: string;
  /** URL of the school instance (Pronote URL, etc.) */
  instanceUrl: string;
  createdAt: number;
}

// --- Child / Student ---

export type ChildSource = "pronote" | "ent";

export interface Child {
  id: string;
  accountId: string;
  firstName: string;
  lastName: string;
  className: string;
  avatarUri?: string;
  source?: ChildSource;
  hasGrades?: boolean;
  hasSchedule?: boolean;
  hasHomework?: boolean;
  hasMessages?: boolean;
}

// --- Grades ---

export interface Grade {
  id: string;
  childId: string;
  subject: string;
  value: number;
  outOf: number;
  coefficient: number;
  date: string; // ISO date
  comment?: string;
  classAverage?: number;
  classMin?: number;
  classMax?: number;
}

export interface SubjectAverage {
  subject: string;
  childId: string;
  average: number;
  classAverage: number;
  /** Number of grades in this subject */
  gradeCount: number;
}

// --- Schedule ---

export interface ScheduleEntry {
  id: string;
  childId: string;
  subject: string;
  teacher: string;
  room: string;
  startTime: string; // ISO datetime
  endTime: string;
  isCancelled: boolean;
  isModified: boolean;
  status?: string;
}

// --- Homework ---

export interface Homework {
  id: string;
  childId: string;
  subject: string;
  description: string;
  dueDate: string; // ISO date
  isDone: boolean;
}

// --- Absences & Delays ---

export interface Absence {
  id: string;
  childId: string;
  from: string; // ISO datetime
  to: string;
  justified: boolean;
  reason?: string;
}

// --- Communication ---

export interface Message {
  id: string;
  accountId: string;
  subject: string;
  from: string;
  date: string; // ISO datetime
  body: string;
  isRead: boolean;
}
