// Bridge between Swift (JavaScriptCore) and pawnote
// This file is bundled with all dependencies into pawnote-bundle.js
//
// WARNING: bundle hand-patched (fetchLessonContents + loginENT); do not
// rebuild without re-applying both. pawnote-bundle.js carries the real
// versions of these two functions (they call bundle-internal helpers:
// `ns` / `Q.Resources` / `le` for fetchLessonContents, Identification with
// pourENT:true for loginENT). The versions below document the intent only.

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
  // read-only. HAND-PATCHED in pawnote-bundle.js (search "NOTO HAND PATCH
  // (3.8)"): the bundle calls the internal request helper directly, i.e. the
  // equivalent of `pronote.resourcesFromIntervals(session, start, end)`, and
  // maps the raw `ListeCahierDeTextes.V[]` entries (N, Matiere, Date, DateFin,
  // listeContenus[] { N, L, descriptif, categorie, ListeThemes }) itself.
  // Returns { entries, rawKeys, rawEntryKeys, rawContentKeys } — key NAMES
  // only for the DEBUG shape check, never values. The raw shape is unverified
  // on a live parent account. Lesson text stays on the device.
  fetchLessonContents: async (session, startDateISO, endDateISO) => {
    const empty = { entries: [], rawKeys: [], rawEntryKeys: [], rawContentKeys: [] };
    const start = new Date(startDateISO);
    const end = new Date(endDateISO);
    // Placeholder (like loginENT below): the real fetch + mapping live in the
    // bundle patch. A rebuild must copy that block back here.
    await pronote.resourcesFromIntervals(session, start, end);
    return empty;
  },

  // ENT/CAS login — uses CAS cookies (pre-transferred to URLSession) for SSO auth.
  // NOTE: This source version uses loginCredentials as a placeholder.
  // The actual pawnote-bundle.js has a hand-patched version that calls
  // Identification with pourENT:true (useCAS:true) for proper CAS auth.
  // If rebuilding the bundle, the hand-patched loginENT in pawnote-bundle.js
  // must be re-applied (see the block above fetchDiscussions in the bundle).
  loginENT: async (session, url, deviceUUID) => {
    let refresh;
    try {
      refresh = await pronote.loginCredentials(session, {
        url,
        kind: pronote.AccountKind.PARENT,
        username: "",
        password: "",
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
