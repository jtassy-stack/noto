import { ENT_PROVIDERS, getEntProvider } from "../lib/ent/providers";

describe("ENT Providers", () => {
  it("has Mon Lycée provider", () => {
    const provider = getEntProvider("monlycee");
    expect(provider).toBeDefined();
    expect(provider?.name).toBe("Mon Lycée");
    expect(provider?.apiBaseUrl).toContain("monlycee.net");
    expect(provider?.messagingType).toBe("zimbra");
  });

  it("has PCN provider", () => {
    const provider = getEntProvider("pcn");
    expect(provider).toBeDefined();
    expect(provider?.name).toBe("Paris Classe Numérique");
    expect(provider?.apiBaseUrl).toContain("parisclassenumerique.fr");
    expect(provider?.messagingType).toBe("conversation");
  });

  it("returns undefined for unknown provider", () => {
    expect(getEntProvider("unknown")).toBeUndefined();
    expect(getEntProvider("")).toBeUndefined();
  });

  it("all providers have required fields", () => {
    for (const provider of ENT_PROVIDERS) {
      expect(provider.id).toBeTruthy();
      expect(provider.name).toBeTruthy();
      expect(provider.apiBaseUrl).toMatch(/^https:\/\//);
      expect(provider.color).toMatch(/^#/);
      expect(["zimbra", "conversation"]).toContain(provider.messagingType);
    }
  });
});
