import * as SQLite from "expo-sqlite";
import { CREATE_TABLES, SCHEMA_VERSION } from "./schema";

const DB_NAME = "noto.db";

let db: SQLite.SQLiteDatabase | null = null;
let initPromise: Promise<SQLite.SQLiteDatabase> | null = null;

export async function getDatabase(): Promise<SQLite.SQLiteDatabase> {
  if (db) return db;
  if (initPromise) return initPromise;

  initPromise = (async () => {
    const instance = await SQLite.openDatabaseAsync(DB_NAME);
    await instance.execAsync("PRAGMA journal_mode = WAL;");
    await instance.execAsync("PRAGMA foreign_keys = ON;");
    await instance.execAsync(CREATE_TABLES);

    // Check and update schema version
    const rows = await instance.getAllAsync<{ version: number }>(
      "SELECT version FROM schema_version LIMIT 1"
    );
    if (rows.length === 0) {
      await instance.runAsync("INSERT INTO schema_version (version) VALUES (?)", [
        SCHEMA_VERSION,
      ]);
    }

    db = instance;
    return instance;
  })();

  try {
    return await initPromise;
  } catch (e) {
    initPromise = null;
    throw e;
  }
}

export async function closeDatabase(): Promise<void> {
  if (db) {
    await db.closeAsync();
    db = null;
  }
}
