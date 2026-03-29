import { stripHtml } from "../lib/utils/html";

describe("stripHtml", () => {
  it("removes basic HTML tags", () => {
    expect(stripHtml("<p>Hello</p>")).toBe("Hello");
    expect(stripHtml("<strong>Bold</strong>")).toBe("Bold");
    expect(stripHtml("<a href='url'>Link</a>")).toBe("Link");
  });

  it("converts <br> to newlines", () => {
    expect(stripHtml("Line 1<br>Line 2")).toBe("Line 1\nLine 2");
    expect(stripHtml("Line 1<br/>Line 2")).toBe("Line 1\nLine 2");
    expect(stripHtml("Line 1<br />Line 2")).toBe("Line 1\nLine 2");
  });

  it("converts </p> to double newlines", () => {
    expect(stripHtml("<p>Para 1</p><p>Para 2</p>")).toBe("Para 1\n\nPara 2");
  });

  it("converts <li> to bullet points", () => {
    expect(stripHtml("<ul><li>Item 1</li><li>Item 2</li></ul>")).toBe("• Item 1\n• Item 2");
  });

  it("decodes &apos; and &#39;", () => {
    expect(stripHtml("l&apos;école")).toBe("l'école");
    expect(stripHtml("l&#39;école")).toBe("l'école");
    expect(stripHtml("l&#x27;école")).toBe("l'école");
  });

  it("decodes common HTML entities", () => {
    expect(stripHtml("&amp;")).toBe("&");
    expect(stripHtml("&lt;")).toBe("<");
    expect(stripHtml("&gt;")).toBe(">");
    expect(stripHtml("&quot;")).toBe('"');
    expect(stripHtml("hello&nbsp;world")).toBe("hello world");
  });

  it("decodes French accent entities", () => {
    expect(stripHtml("&eacute;")).toBe("é");
    expect(stripHtml("&egrave;")).toBe("è");
    expect(stripHtml("&agrave;")).toBe("à");
    expect(stripHtml("&ccedil;")).toBe("ç");
    expect(stripHtml("&ocirc;")).toBe("ô");
    expect(stripHtml("&ecirc;")).toBe("ê");
  });

  it("decodes numeric entities", () => {
    expect(stripHtml("&#233;")).toBe("é"); // é
    expect(stripHtml("&#8217;")).toBe("\u2019"); // right single quote
    expect(stripHtml("&#x00E9;")).toBe("é"); // é hex
  });

  it("collapses multiple newlines", () => {
    expect(stripHtml("<p></p><p></p><p>Text</p>")).toBe("Text");
  });

  it("trims whitespace", () => {
    expect(stripHtml("  <p>  Hello  </p>  ")).toBe("Hello");
  });

  it("handles real PCN message content", () => {
    const html = `<p>Chers parents,</p><p></p><p>Il y a eu un problème avec le mail de l&apos;école et certains d&apos;entre vous n&apos;ont pas reçu l&apos;information.</p>`;
    const result = stripHtml(html);
    expect(result).toContain("l'école");
    expect(result).toContain("d'entre vous");
    expect(result).not.toContain("&apos;");
    expect(result).not.toContain("<p>");
  });
});
