# Phase 02 CONTEXT.md — Missing canonical_refs

<domain>
- Document management platform
- Supports PDF, Word, and Markdown formats
</domain>

<decisions>
- D-01: Store files in S3-compatible object storage
- D-02: Full-text search via Elasticsearch
</decisions>

<specifics>
- Upload size limit: 100MB per file
- Retention policy: 7 years for compliance documents
</specifics>

<code_context>
- `src/storage/` — S3 upload/download wrappers
- `src/search/` — Elasticsearch indexing pipeline
</code_context>

<deferred>
- Add OCR pipeline for scanned PDFs
- Implement document versioning
</deferred>
