import * as SQLite from "expo-sqlite";
import { CREATE_TABLES, SCHEMA_VERSION } from "./schema";

const DB_NAME = "noto.db";

let db: SQLite.SQLiteDatabase | null = null;

export async function getDatabase(): Promise<SQLite.SQLiteDatabase> {
  if (db) return db;

  db = await SQLite.openDatabaseAsync(DB_NAME);
  await db.execAsync("PRAGMA journal_mode = WAL;");
  await db.execAsync("PRAGMA foreign_keys = ON;");
  await db.execAsync(CREATE_TABLES);

  // Check and update schema version
  const rows = await db.getAllAsync<{ version: number }>(
    "SELECT version FROM schema_version LIMIT 1"
  );
  if (rows.length === 0) {
    await db.runAsync("INSERT INTO schema_version (version) VALUES (?)", [
      SCHEMA_VERSION,
    ]);
  }

  return db;
}

export async function closeDatabase(): Promise<void> {
  if (db) {
    await db.closeAsync();
    db = null;
  }
}
