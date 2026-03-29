module.exports = {
  preset: "ts-jest",
  testEnvironment: "node",
  roots: ["<rootDir>/src"],
  moduleNameMapper: {
    "^@/(.*)$": "<rootDir>/src/$1",
    "^expo-secure-store$": "<rootDir>/src/__tests__/__mocks__/expo-secure-store.ts",
    "^expo-crypto$": "<rootDir>/src/__tests__/__mocks__/expo-crypto.ts",
  },
  testMatch: ["**/__tests__/**/*.test.ts"],
  transform: {
    "^.+\\.tsx?$": ["ts-jest", {
      tsconfig: "tsconfig.json",
      diagnostics: false,
    }],
  },
};
