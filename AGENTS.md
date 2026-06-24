# AI Pet Collaboration Rules

These rules apply to the whole repository.

- Every completed project change must be committed to Git before the work is considered done.
- Before committing, run the relevant checks for the touched area; for broad changes, run the full test suite.
- Do not commit local secrets, runtime data, logs, caches, virtual environments, OpenClaw runtime files, or local-only evolution notes.
- Keep `.env.local`, `.data/`, `logs/`, `.cache/`, `.openclaw/`, `.venv/`, and `TECHNICAL_EVOLUTION.local.md` out of Git.
- When a change affects the real WeChat account flow, keep fail-closed behavior and document any safety-control relaxation before enabling it.
