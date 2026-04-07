// Bridge between Swift (JavaScriptCore) and pawnote
// This file is bundled with all dependencies into pawnote-bundle.js

import * as pronote from "@niicojs/pawnote";

// Expose to JavaScriptCore global scope
globalThis.PawnoteBridge = {
  // Create a new session handle
  createSession: () => {
    return pronote.createSessionHandle();
  },

  // QR Code login
  loginQrCode: async (session, deviceUUID, pin, qrData) => {
    const refresh = await pronote.loginQrCode(session, {
      deviceUUID,
      pin,
      qr: qrData,
    });
    return {
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
    };
  },

  // Token login (reconnection)
  loginToken: async (session, url, username, token, deviceUUID) => {
    const refresh = await pronote.loginToken(session, {
      url,
      kind: pronote.AccountKind.PARENT,
      username,
      token,
      deviceUUID,
    });
    return {
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
    };
  },

  // Credentials login
  loginCredentials: async (session, url, username, password, deviceUUID) => {
    const refresh = await pronote.loginCredentials(session, {
      url,
      kind: pronote.AccountKind.PARENT,
      username,
      password,
      deviceUUID,
    });
    return {
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
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
    }));
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
