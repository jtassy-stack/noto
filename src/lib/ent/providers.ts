/**
 * ENT provider registry.
 * Each ENT has its own Keycloak realm, client ID, and base URLs.
 * Add new ENTs here to support more regions.
 */

export interface EntProvider {
  id: string;
  name: string;
  description: string;
  region: string;
  icon: string;
  // Keycloak OIDC config
  authBaseUrl: string;
  realm: string;
  clientId: string;
  // ENT API base URL (for messaging, SSO, etc.)
  apiBaseUrl: string;
  // Messaging type
  messagingType: "zimbra" | "conversation";
  // CAS base URL for Pronote SSO
  casBaseUrl: string;
  // Color for the login button
  color: string;
}

export const ENT_PROVIDERS: EntProvider[] = [
  {
    id: "monlycee",
    name: "Mon Lycée",
    description: "Lycées Île-de-France",
    region: "Île-de-France",
    icon: "🏫",
    authBaseUrl: "https://ent.iledefrance.fr",
    realm: "IDF",
    clientId: "psn-web-een",
    apiBaseUrl: "https://ent.iledefrance.fr",
    messagingType: "zimbra",
    casBaseUrl: "https://ent.iledefrance.fr",
    color: "#1B3A6B",
  },
  {
    id: "pcn",
    name: "Paris Classe Numérique",
    description: "Collèges Paris",
    region: "Paris",
    icon: "🗼",
    // PCN uses the same Edifice/ENTCore platform
    authBaseUrl: "https://auth.parisclassenumerique.fr",
    realm: "PCN",
    clientId: "pcn-web",
    apiBaseUrl: "https://parisclassenumerique.fr",
    messagingType: "conversation",
    casBaseUrl: "https://parisclassenumerique.fr",
    color: "#E30613",
  },
];

export function getEntProvider(id: string): EntProvider | undefined {
  return ENT_PROVIDERS.find((p) => p.id === id);
}
