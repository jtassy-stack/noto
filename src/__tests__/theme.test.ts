import { gradeColor, LightTheme, DarkTheme } from "../constants/theme";

describe("gradeColor", () => {
  it("returns excellent color for high grades", () => {
    expect(gradeColor(18, 20, LightTheme)).toBe(LightTheme.gradeExcellent);
    expect(gradeColor(16, 20, DarkTheme)).toBe(DarkTheme.gradeExcellent);
  });

  it("returns good color for above-average grades", () => {
    expect(gradeColor(13, 20, LightTheme)).toBe(LightTheme.gradeGood);
  });

  it("returns average color for middle grades", () => {
    expect(gradeColor(11, 20, LightTheme)).toBe(LightTheme.gradeAverage);
  });

  it("returns fail color for low grades", () => {
    expect(gradeColor(6, 20, LightTheme)).toBe(LightTheme.gradeFail);
    expect(gradeColor(3, 20, DarkTheme)).toBe(DarkTheme.gradeFail);
  });

  it("handles grades with different outOf values", () => {
    // 8/10 = 80% → excellent
    expect(gradeColor(8, 10, LightTheme)).toBe(LightTheme.gradeExcellent);
    // 3/5 = 60% → good
    expect(gradeColor(3, 5, LightTheme)).toBe(LightTheme.gradeGood);
    // 2/5 = 40% → fail
    expect(gradeColor(2, 5, LightTheme)).toBe(LightTheme.gradeFail);
  });
});

describe("Theme tokens", () => {
  it("LightTheme has required colors", () => {
    expect(LightTheme.background).toBeDefined();
    expect(LightTheme.text).toBeDefined();
    expect(LightTheme.accent).toBeDefined();
    expect(LightTheme.crimson).toBeDefined();
  });

  it("DarkTheme has required colors", () => {
    expect(DarkTheme.background).toBeDefined();
    expect(DarkTheme.text).toBeDefined();
    expect(DarkTheme.accent).toBeDefined();
    expect(DarkTheme.crimson).toBeDefined();
  });

  it("Light and dark themes have different backgrounds", () => {
    expect(LightTheme.background).not.toBe(DarkTheme.background);
  });
});
