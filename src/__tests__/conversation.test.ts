import { filterMessagesByChild } from "../lib/ent/conversation";
import type { ConversationMessage } from "../lib/ent/conversation";

function makeMsg(id: string, groupNames: string[]): ConversationMessage {
  return {
    id,
    subject: `Message ${id}`,
    from: "Teacher",
    to: [],
    date: new Date().toISOString(),
    unread: true,
    hasAttachment: false,
    groupNames,
  };
}

describe("filterMessagesByChild", () => {
  const messages: ConversationMessage[] = [
    makeMsg("1", ["Parents du groupe CM1 - CM2 A - M. Lucas TOLOTTA."]),
    makeMsg("2", ["Parents du groupe MS - Mme Céline DESBATS."]),
    makeMsg("3", ["Parents du groupe DOMBASLE (28) POLY - 15108."]),
    makeMsg("4", []), // direct message — no group
    makeMsg("5", ["Parents du groupe CM1 CM2 B - M. Julien FYOT."]),
    makeMsg("6", ["Enseignants du groupe MS - Mme Céline DESBATS."]),
  ];

  it("filters for CM1-CM2 A child", () => {
    const filtered = filterMessagesByChild(messages, "CM1 - CM2 A - M. Lucas TOLOTTA");
    const ids = filtered.map(m => m.id);

    expect(ids).toContain("1"); // CM1-CM2 A group
    expect(ids).toContain("3"); // school-wide (DOMBASLE/POLY)
    expect(ids).toContain("4"); // direct message
    expect(ids).not.toContain("2"); // MS group
    expect(ids).not.toContain("5"); // CM1 CM2 B group
  });

  it("filters for MS child", () => {
    const filtered = filterMessagesByChild(messages, "MS - Mme Céline DESBATS");
    const ids = filtered.map(m => m.id);

    expect(ids).toContain("2"); // MS group
    expect(ids).toContain("3"); // school-wide
    expect(ids).toContain("4"); // direct message
    expect(ids).toContain("6"); // enseignants MS
    expect(ids).not.toContain("1"); // CM1-CM2 A
  });

  it("returns all messages when className is empty", () => {
    const filtered = filterMessagesByChild(messages, "");
    expect(filtered).toHaveLength(messages.length);
  });

  it("includes direct messages (no group) for all children", () => {
    const filtered1 = filterMessagesByChild(messages, "CM1 - CM2 A - M. Lucas TOLOTTA");
    const filtered2 = filterMessagesByChild(messages, "MS - Mme Céline DESBATS");

    expect(filtered1.find(m => m.id === "4")).toBeTruthy();
    expect(filtered2.find(m => m.id === "4")).toBeTruthy();
  });
});
