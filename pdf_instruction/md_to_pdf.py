#!/usr/bin/env python3
"""
Конвертация Markdown → PDF через Chrome headless.
Зависимости: pip install markdown  (больше ничего не нужно)
Требует: Google Chrome (установлен в /Applications)
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

import markdown

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

CSS = """
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&family=JetBrains+Mono:wght@400;700&display=swap');

*, *::before, *::after { box-sizing: border-box; }

@page { size: A4; margin: 2.2cm 2.4cm 2.4cm 2.4cm; }

body {
  font-family: 'Inter', -apple-system, 'Segoe UI', sans-serif;
  font-size: 11pt;
  line-height: 1.65;
  color: #1e293b;
}

h1 {
  font-size: 22pt;
  font-weight: 700;
  color: #0f172a;
  margin: 0 0 0.5em 0;
  padding-bottom: 0.35em;
  border-bottom: 3px solid #3b82f6;
  letter-spacing: -0.02em;
}
h2 {
  font-size: 15pt;
  font-weight: 700;
  color: #1d4ed8;
  margin: 1.6em 0 0.5em 0;
  padding-bottom: 0.2em;
  border-bottom: 1px solid #dbeafe;
}
h3 {
  font-size: 12pt;
  font-weight: 600;
  color: #334155;
  margin: 1.2em 0 0.4em 0;
}

p { margin: 0.6em 0; }

ul, ol { margin: 0.5em 0; padding-left: 1.5em; }
li { margin: 0.3em 0; }

a { color: #2563eb; text-decoration: none; }

code {
  font-family: 'JetBrains Mono', 'Fira Code', 'Consolas', monospace;
  font-size: 9pt;
  background: #f1f5f9;
  color: #0f172a;
  padding: 0.15em 0.4em;
  border-radius: 4px;
  border: 1px solid #e2e8f0;
}

pre {
  background: #0f172a;
  border-radius: 8px;
  padding: 1em 1.2em;
  overflow-x: auto;
  margin: 1em 0;
  border-left: 4px solid #3b82f6;
}
pre code {
  background: none;
  border: none;
  padding: 0;
  color: #e2e8f0;
  font-size: 8.5pt;
  line-height: 1.5;
}

blockquote {
  margin: 1em 0;
  padding: 0.6em 0.8em 0.6em 1em;
  border-left: 4px solid #3b82f6;
  background: #eff6ff;
  color: #1e40af;
  border-radius: 0 6px 6px 0;
}

hr {
  border: none;
  border-top: 2px solid #e2e8f0;
  margin: 1.8em 0;
}

table {
  border-collapse: collapse;
  width: 100%;
  margin: 1em 0;
  font-size: 10pt;
}
th {
  background: #1d4ed8;
  color: #fff;
  font-weight: 600;
  padding: 0.5em 0.8em;
  text-align: left;
}
td {
  padding: 0.45em 0.8em;
  border-bottom: 1px solid #e2e8f0;
}
tr:nth-child(even) td { background: #f8fafc; }

strong { color: #0f172a; font-weight: 600; }
"""


def convert(src: Path, out: Path) -> None:
    md_text = src.read_text(encoding="utf-8")
    body = markdown.markdown(
        md_text,
        extensions=[
            "markdown.extensions.fenced_code",
            "markdown.extensions.tables",
            "markdown.extensions.nl2br",
            "markdown.extensions.sane_lists",
        ],
    )
    html = f"""<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8"/>
  <style>{CSS}</style>
</head>
<body>
{body}
</body>
</html>"""

    with tempfile.NamedTemporaryFile(suffix=".html", mode="w", encoding="utf-8", delete=False) as f:
        f.write(html)
        tmp_html = f.name

    subprocess.run(
        [
            CHROME,
            "--headless=old",
            "--no-sandbox",
            "--disable-gpu",
            f"--print-to-pdf={out}",
            "--print-to-pdf-no-header",
            f"file://{tmp_html}",
        ],
        check=True,
        capture_output=True,
    )
    Path(tmp_html).unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Markdown → PDF (Chrome headless)")
    parser.add_argument("input", type=Path)
    parser.add_argument("-o", "--output", type=Path, default=None)
    args = parser.parse_args()

    src = args.input.expanduser().resolve()
    out = args.output.expanduser().resolve() if args.output else src.with_suffix(".pdf")

    if not src.is_file():
        print(f"Файл не найден: {src}", file=sys.stderr)
        return 1

    convert(src, out)
    print(f"Готово: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
