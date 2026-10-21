// A small two-page PDF for tests: typed text on both pages, a web link and a link to page 2, and a
// form (a text field, a check box, two radio buttons and a choice list). Written by hand so the
// tests don't need a PDF library.

export function formPdf() {
  const objects = [];
  const add = (body) => { objects.push(body); return objects.length; };
  const font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
  const text = (lines) => lines.map(([x, y, size, s]) => `BT /F1 ${size} Tf ${x} ${y} Td (${s}) Tj ET`).join("\n");
  const stream = (s) => add(`<< /Length ${s.length} >>\nstream\n${s}\nendstream`);
  const c1 = stream(text([[72, 720, 18, "Trove test document"], [72, 690, 12, "The quick brown fox jumps over the lazy dog."],
    [72, 674, 12, "Pack my box with five dozen liquor jugs."], [72, 600, 12, "Name:"], [72, 560, 12, "I agree"], [72, 520, 12, "Colour:"],
    [72, 480, 12, "Size:"], [72, 420, 12, "Visit the website or go to page two."]]));
  const c2 = stream(text([[72, 720, 18, "Page two"], [72, 690, 12, "The second page also mentions the quick brown fox."]]));
  // Pages are numbered after the fields so the links can point at page 2.
  const page1 = objects.length + 1, page2 = objects.length + 2;
  objects.push(null, null);
  const fieldName = add(`<< /FT /Tx /T (name) /Rect [120 594 320 614] /Type /Annot /Subtype /Widget /P ${page1} 0 R /DA (/Helv 12 Tf 0 g) /F 4 >>`);
  const fieldAgree = add(`<< /FT /Btn /T (agree) /Rect [120 556 134 570] /Type /Annot /Subtype /Widget /P ${page1} 0 R /V /Off /AS /Off /F 4 /MK << /CA (4) >> /DA (/ZaDb 0 Tf 0 g) /AP << /N << /Yes ${stream("q 0 0 1 rg 2 2 10 10 re f Q")} 0 R /Off ${stream("")} 0 R >> >> >>`);
  const radioParent = objects.length + 1;
  objects.push(null);
  const red = add(`<< /Type /Annot /Subtype /Widget /Parent ${radioParent} 0 R /Rect [130 516 144 530] /P ${page1} 0 R /AS /Off /F 4 /MK << /CA (l) >> /AP << /N << /Red ${stream("q 1 0 0 rg 3 3 8 8 re f Q")} 0 R /Off ${stream("")} 0 R >> >> >>`);
  const blue = add(`<< /Type /Annot /Subtype /Widget /Parent ${radioParent} 0 R /Rect [170 516 184 530] /P ${page1} 0 R /AS /Off /F 4 /MK << /CA (l) >> /AP << /N << /Blue ${stream("q 0 0 1 rg 3 3 8 8 re f Q")} 0 R /Off ${stream("")} 0 R >> >> >>`);
  objects[radioParent - 1] = `<< /FT /Btn /Ff 49152 /T (colour) /V /Off /Kids [${red} 0 R ${blue} 0 R] >>`;
  const fieldSize = add(`<< /FT /Ch /Ff 131072 /T (size) /Opt [(Small) (Medium) (Large)] /Rect [120 474 260 494] /Type /Annot /Subtype /Widget /P ${page1} 0 R /DA (/Helv 12 Tf 0 g) /F 4 >>`);
  const web = add("<< /Type /Annot /Subtype /Link /Rect [130 416 190 430] /Border [0 0 0] /A << /S /URI /URI (https://example.com/trove) >> >>");
  const toPage2 = add(`<< /Type /Annot /Subtype /Link /Rect [240 416 300 430] /Border [0 0 0] /Dest [${page2} 0 R /XYZ 0 792 0] >>`);
  const pages = add(`<< /Type /Pages /Kids [${page1} 0 R ${page2} 0 R] /Count 2 >>`);
  const res = `/Resources << /Font << /F1 ${font} 0 R /Helv ${font} 0 R >> >>`;
  objects[page1 - 1] = `<< /Type /Page /Parent ${pages} 0 R /MediaBox [0 0 612 792] /Contents ${c1} 0 R ${res} /Annots [${fieldName} 0 R ${fieldAgree} 0 R ${red} 0 R ${blue} 0 R ${fieldSize} 0 R ${web} 0 R ${toPage2} 0 R] >>`;
  objects[page2 - 1] = `<< /Type /Page /Parent ${pages} 0 R /MediaBox [0 0 612 792] /Contents ${c2} 0 R ${res} >>`;
  const form = add(`<< /Fields [${fieldName} 0 R ${fieldAgree} 0 R ${radioParent} 0 R ${fieldSize} 0 R] /NeedAppearances true /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv ${font} 0 R >> >> >>`);
  const catalog = add(`<< /Type /Catalog /Pages ${pages} 0 R /AcroForm ${form} 0 R >>`);
  let out = "%PDF-1.7\n";
  const offsets = objects.map((body, i) => { const at = out.length; out += `${i + 1} 0 obj\n${body}\nendobj\n`; return at; });
  const xref = out.length;
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("")}`;
  out += `trailer\n<< /Size ${objects.length + 1} /Root ${catalog} 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Uint8Array.from(out, (c) => c.charCodeAt(0));
}
