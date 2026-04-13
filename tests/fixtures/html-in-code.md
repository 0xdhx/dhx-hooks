# Phase 20 CONTEXT.md — HTML tags inside fenced code blocks (alembic pattern)

<domain>
- Alembic database migration tooling integration
- Django project with custom migration tooling
</domain>

<decisions>
- D-01: Add meta viewport and stylesheet link to migration preview page
- D-02: Render migration diff as HTML with syntax highlighting
</decisions>

<specifics>
- Migration preview page template includes the following HTML boilerplate:

```html
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="/static/diff.css">
</head>
<body>
  <div id="migration-diff"></div>
</body>
</html>
```

- The `<meta name="viewport">` and `<link rel="stylesheet">` tags are required for mobile rendering.
</specifics>

<code_context>
- `src/migrations/` — Custom migration runner
- `templates/migration-preview.html` — Preview page template
</code_context>

<canonical_refs>
- `docs/migration-preview.md` — Preview feature design
</canonical_refs>

<deferred>
- Add side-by-side diff view for large migrations
</deferred>
