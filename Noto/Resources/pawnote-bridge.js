// Bridge between Swift (JavaScriptCore) and pawnote
// This file is bundled with all dependencies into pawnote-bundle.js
//
// Rebuild with `tools/pawnote-bundle/build.sh` (pinned pawnote + esbuild,
// no hand patch: CI checks that the committed bundle matches). ENT logins
// do not go through the bundle: the web view captures the mobile token on
// Pronote's own page (PronoteMobileLogin.swift) and the session opens with
// loginToken, like after a QR scan.

import * as pronote from "@niicojs/pawnote";

// Expose to JavaScriptCore global scope
globalThis.PawnoteBridge = {
  // Create a new session handle
  createSession: () => {
    return pronote.createSessionHandle();
  },

  // Pronote answered the authentication with `actionsDoubleAuth`: the
  // account must set up (or confirm) its double authentication in Pronote
  // before the session is usable. pawnote throws a SecurityError there, but
  // Pronote's answer already carries the renewed single-use mobile token, so
  // the error is rethrown with everything Swift needs to keep the account
  // alive (PronoteError.doubleAuthRequired). Any other error passes through.
  _doubleAuthError: (session, e) => {
    if (!e || e.name !== "SecurityError") return e;
    const h = e.handle || {};
    const ctx = h.context || {};
    const auth = ctx.authentication || {};
    const payload = {
      token: auth.jetonConnexionAppliMobile || null,
      username: ctx.initialUsername || (ctx.identity && ctx.identity.login) || null,
      url: (session.information && session.information.url) || null,
      kind: (session.information && session.information.accountKind) || null,
      navigatorIdentifier: (session.instance && session.instance.navigatorIdentifier) || null,
      needsPIN: Boolean(h.shouldEnterPIN),
      needsChoice: Boolean(h.shouldCustomDoubleAuth),
      needsPassword: Boolean(h.shouldCustomPassword),
    };
    return new Error("DOUBLE_AUTH_REQUIRED:" + JSON.stringify(payload));
  },

  // QR Code login
  loginQrCode: async (session, deviceUUID, pin, qrData) => {
    let refresh;
    try {
      refresh = await pronote.loginQrCode(session, {
        deviceUUID,
        pin,
        qr: qrData,
      });
    } catch (e) {
      throw globalThis.PawnoteBridge._doubleAuthError(session, e);
    }
    return {
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
      navigatorIdentifier: refresh.navigatorIdentifier ?? null,
    };
  },

  // Token login (reconnection). `kind` is the numeric AccountKind the
  // previous login returned (6 élève / 7 parent / 8 professeur) and
  // `navigatorIdentifier` the `identifiantNav` Pronote handed out then:
  // both must be replayed, Pronote refuses a mobile token presented for
  // another space or from an unknown navigator. Missing values fall back
  // to the pre-fix behaviour (parent, fresh navigator).
  // A SecurityError (Pronote asks to set up double authentication) is
  // rethrown via _doubleAuthError (see above).
  loginToken: async (session, url, username, token, deviceUUID, kind, navigatorIdentifier) => {
    let refresh;
    try {
      refresh = await pronote.loginToken(session, {
        url,
        kind: typeof kind === "number" && kind > 0 ? kind : pronote.AccountKind.PARENT,
        username,
        token,
        deviceUUID,
        navigatorIdentifier: navigatorIdentifier || undefined,
      });
    } catch (e) {
      throw globalThis.PawnoteBridge._doubleAuthError(session, e);
    }
    return {
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
      navigatorIdentifier: refresh.navigatorIdentifier ?? null,
    };
  },

  // Credentials login
  loginCredentials: async (session, url, username, password, deviceUUID) => {
    let refresh;
    try {
      refresh = await pronote.loginCredentials(session, {
        url,
        kind: pronote.AccountKind.PARENT,
        username,
        password,
        deviceUUID,
      });
    } catch (e) {
      throw globalThis.PawnoteBridge._doubleAuthError(session, e);
    }
    return {
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
      navigatorIdentifier: refresh.navigatorIdentifier ?? null,
    };
  },

  // Get children from session
  getChildren: (session) => {
    return session.user.resources.map((r) => ({
      id: r.id,
      name: r.name,
      className: r.className ?? "",
    }));
  },

  // Set active child resource
  setActiveChild: (session, index) => {
    session.userResource = session.user.resources[index];
  },

  // Fetch grades
  fetchGrades: async (session) => {
    const gradesTab = session.userResource.tabs.get(pronote.TabLocation.Grades);
    if (!gradesTab) return [];

    const period = gradesTab.defaultPeriod ?? gradesTab.periods[gradesTab.periods.length - 1];
    if (!period) return [];

    const overview = await pronote.gradesOverview(session, period);
    return overview.grades.map((g) => ({
      id: g.id,
      subject: g.subject.name,
      value: g.value.kind === pronote.GradeKind.Grade ? g.value.points : null,
      kind: g.value.kind,
      outOf: g.outOf.points,
      coefficient: g.coefficient,
      date: g.date.toISOString(),
      comment: g.comment ?? null,
      classAverage: g.average?.kind === pronote.GradeKind.Grade ? g.average.points : null,
      classMin: g.min?.kind === pronote.GradeKind.Grade ? g.min.points : null,
      classMax: g.max?.kind === pronote.GradeKind.Grade ? g.max.points : null,
    }));
  },

  // Fetch timetable
  fetchTimetable: async (session, startDateISO, endDateISO) => {
    const start = new Date(startDateISO);
    const end = new Date(endDateISO);
    const timetable = await pronote.timetableFromIntervals(session, start, end);
    pronote.parseTimetable(session, timetable, {
      withCanceledClasses: true,
      withPlannedClasses: true,
      withSuperposedCanceledClasses: false,
    });

    return timetable.classes
      .filter((c) => c.is === "lesson")
      .map((lesson) => ({
        id: lesson.id,
        subject: lesson.subject?.name ?? null,
        startDate: lesson.startDate.toISOString(),
        endDate: lesson.endDate.toISOString(),
        cancelled: lesson.canceled,
        status: lesson.status ?? null,
        teacherNames: lesson.teacherNames,
        classrooms: lesson.classrooms,
        isTest: lesson.test,
        lessonResourceID: lesson.lessonResourceID ?? null,
      }));
  },

  // Fetch homework
  fetchHomework: async (session, startDateISO, endDateISO) => {
    const start = new Date(startDateISO);
    const end = new Date(endDateISO);
    const assignments = await pronote.assignmentsFromIntervals(session, start, end);

    return assignments.map((a) => ({
      id: a.id,
      subject: a.subject.name,
      description: a.description.replace(/<[^>]+>/g, "").trim(),
      deadline: a.deadline.toISOString(),
      done: a.done,
      difficulty: a.difficulty,
      themes: a.themes.map((t) => t.name ?? t),
      resourceID: a.resourceID ?? null,
    }));
  },

  // Cahier de textes lesson contents (Pronote onglet 89, PageCahierDeTexte),
  // read-only, through pawnote's public `resourcesFromIntervals`. Returns
  // { entries, rawKeys, rawEntryKeys, rawContentKeys } — key NAMES only for
  // the DEBUG shape check, never values. Lesson text stays on the device.
  fetchLessonContents: async (session, startDateISO, endDateISO) => {
    const empty = { entries: [], rawKeys: [], rawEntryKeys: [], rawContentKeys: [] };
    const resourceTabs = session.userResource?.tabs;
    const userTabs = session.user?.authorizations?.tabs;
    const tab = pronote.TabLocation.Resources;
    const hasTab = (resourceTabs?.has?.(tab) ?? false) || (Array.isArray(userTabs) && userTabs.includes(tab));
    if (!hasTab) return empty;

    let start = new Date(startDateISO);
    const end = new Date(endDateISO);
    // Pronote refuses intervals before the school year's first Monday.
    const firstMonday = session.instance?.firstMonday;
    if (firstMonday instanceof Date && start < firstMonday) start = firstMonday;
    if (!(start <= end)) return empty;

    const resources = await pronote.resourcesFromIntervals(session, start, end);
    const strip = (h) => String(h ?? "")
      .replace(/<[^>]+>/g, " ")
      .replace(/&nbsp;/g, " ")
      .replace(/&amp;/g, "&")
      .replace(/&#39;|&apos;/g, "'")
      .replace(/&quot;/g, '"')
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/\s+/g, " ")
      .trim();
    const iso = (d) => (d instanceof Date && !isNaN(d.getTime()) ? d.toISOString() : null);

    const entries = resources
      .map((r) => ({
        id: r.id ?? null,
        subject: r.subject?.name ?? null,
        startDate: iso(r.startDate),
        endDate: iso(r.endDate),
        contents: (r.contents ?? []).map((c) => ({
          id: c.id ?? null,
          title: strip(c.title),
          description: strip(c.description),
          categoryLabel: c.categoryText ?? null,
          themes: (c.themes ?? []).map((t) => t?.name ?? t).filter(Boolean),
        })),
      }))
      .filter((r) => r.startDate && start <= new Date(r.startDate) && new Date(r.startDate) <= end);

    const first = resources[0];
    const firstContent = first?.contents?.[0];
    return {
      entries,
      rawKeys: ["resources"],
      rawEntryKeys: first ? Object.keys(first) : [],
      rawContentKeys: firstContent ? Object.keys(firstContent) : [],
    };
  },

  // Fetch discussions
  fetchDiscussions: async (session) => {
    if (!session.user.authorizations.canReadDiscussions) return [];
    const result = await pronote.discussions(session);
    return result.items.map((d) => ({
      id: d.participantsMessageID,
      subject: d.subject,
      creator: d.creator ?? d.recipientName ?? null,
      date: d.date.toISOString(),
      unreadCount: d.numberOfMessagesUnread,
    }));
  },
};
