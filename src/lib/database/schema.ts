/**
 * SQLite schema for local-first storage.
 * All school data stays on-device — zero server storage.
 */

export const SCHEMA_VERSION = 1;

export const CREATE_TABLES = `
  CREATE TABLE IF NOT EXISTS accounts (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL CHECK(provider IN ('pronote', 'ecoledirecte', 'skolengo')),
    display_name TEXT NOT NULL,
    instance_url TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
  );

  CREATE TABLE IF NOT EXISTS children (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    class_name TEXT NOT NULL,
    avatar_uri TEXT
  );

  CREATE TABLE IF NOT EXISTS grades (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
    subject TEXT NOT NULL,
    value REAL NOT NULL,
    out_of REAL NOT NULL,
    coefficient REAL NOT NULL DEFAULT 1.0,
    date TEXT NOT NULL,
    comment TEXT,
    class_average REAL,
    class_min REAL,
    class_max REAL
  );

  CREATE TABLE IF NOT EXISTS schedule (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
    subject TEXT NOT NULL,
    teacher TEXT NOT NULL,
    room TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    is_cancelled INTEGER NOT NULL DEFAULT 0,
    is_modified INTEGER NOT NULL DEFAULT 0,
    status TEXT
  );

  CREATE TABLE IF NOT EXISTS homework (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
    subject TEXT NOT NULL,
    description TEXT NOT NULL,
    due_date TEXT NOT NULL,
    is_done INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS absences (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
    from_time TEXT NOT NULL,
    to_time TEXT NOT NULL,
    justified INTEGER NOT NULL DEFAULT 0,
    reason TEXT
  );

  CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    subject TEXT NOT NULL,
    sender TEXT NOT NULL,
    date TEXT NOT NULL,
    body TEXT NOT NULL,
    is_read INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS favorites (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    child_id TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
  );

  CREATE TABLE IF NOT EXISTS sync_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_grades_child ON grades(child_id);
  CREATE INDEX IF NOT EXISTS idx_grades_date ON grades(date);
  CREATE INDEX IF NOT EXISTS idx_schedule_child_time ON schedule(child_id, start_time);
  CREATE INDEX IF NOT EXISTS idx_homework_child_due ON homework(child_id, due_date);
`;
