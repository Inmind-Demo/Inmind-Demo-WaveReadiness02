# Page Script Library

A library of recorded Business Central business scenarios, replayed automatically
before each BC wave update to verify that core processes still work on the new
platform version — without anyone clicking through them by hand.

## Purpose

Microsoft ships a major BC wave every April and October, plus monthly minor
updates. Any one of them can change behaviour a business depends on. This library
captures the flows that matter (quote-to-cash, requisition-to-PO, bank
reconciliation, period close…) so they can be replayed against a copy of
production upgraded to the next wave version, before that version reaches prod.

The replay itself is driven by
[`.github/workflows/WaveReadinessValidation.yaml`](../.github/workflows/WaveReadinessValidation.yaml).

## Layout

```
PageScriptLibrary/
  MasterData - 1/        (Phase 1: seed data — runs first, blocks everything on failure)
    ...
  Purchase - 2/          (Phase 2: business scenarios — areas run sequentially,
  Invoice - 3/            in folder-name sort order; the numeric suffix
  Return - 4/             controls that order)
  Payment - 5/
```

- Top-level folders are **functional areas**, replayed sequentially in
  folder-name sort order. A failure in one area is logged but doesn't stop
  the remaining areas.
- One folder name is reserved by the workflow:
  - `MasterData - 1` runs **before** the matrix, sequentially, on its own job.
    Downstream phases depend on the seed data it creates, so a failure here
    short-circuits everything else.
- Every `.yml` at the root of an area folder is a standalone scenario runnable
  by `@microsoft/bc-replay`. No shared `Master.yml` — each script has its own
  `start:` block and is dispatched independently.
- Create a new area folder any time a new BC module needs coverage. The workflow
  discovers areas dynamically at run time.

## Recording a new scenario

The Business Central UI ships with a built-in recorder — no dev tools required.

1. **Open BC as the user whose flow you're capturing** (Business Manager profile
   for most scenarios; use the matching role for specialised flows).
2. Search for **Page Scripting** (or open it from your role centre).
3. Click **+ New** → give the script a short descriptive name
   (e.g. `QuoteToInvoicePost`).
4. Click **Start Recording**. Do the business flow exactly as a user would.
5. Click **Stop Recording** → **Save**.
6. Click **Download** to get the `.yml` file.
7. Drop it into the matching area folder in this directory, using a
   `PascalCase` filename (`QuoteToInvoicePost.yml`), and open a PR.

**Tip**: keep each recording focused on one flow. "Create quote → convert to
order → post shipment → post invoice" is one scenario. "End-to-end sales cycle
including credit memo and reversal" is three scenarios — record them separately
so you get per-flow pass/fail on the report.

## Data assumptions

Scripts reference specific records (vendor no., item no., customer no.) from
whatever the production copy contains. When recording, prefer:

- **Existing reference data** that's stable in production (e.g. a specific
  supplier the business always uses for test orders).
- **Generated values** where uniqueness matters — use bc-replay's formula
  syntax, e.g. `=Text(Now(), "YYYYMMDD-hhmmss")` for vendor invoice numbers.
- **Avoid** hardcoded dates more than a few weeks in the future; workflows that
  care about posting dates will break when the sandbox's workdate drifts.

If a scenario needs dedicated test data (a dummy customer that doesn't exist in
prod), add an idempotent setup step at the top of the script — or record a
separate setup scenario in a `Setup/` area that runs first.

## Running locally

To replay a single script against any sandbox without going through CI:

```powershell
# One-time install
npm install @microsoft/bc-replay

# Set credentials as env vars (never hardcode)
$env:BC_USER = 'bcreplay@yourtenant.onmicrosoft.com'
$env:BC_PASS = '...'

# Run one script
npx replay "PageScriptLibrary/Purchase - 2/MyScenario.yml" `
  -StartAddress 'https://businesscentral.dynamics.com/<tenantId>/<sandbox>/' `
  -Authentication AAD `
  -UserNameKey BC_USER `
  -PasswordKey BC_PASS `
  -ResultDir ./local-results
```

Open `local-results/playwright-report/index.html` to see the run.

## Gotchas

- **Selectors are fragile across wave upgrades**. That's the point — a broken
  selector in the report is an early warning. When a selector shifts, re-record
  the affected step against the upgraded sandbox and commit the new recording.
- **One script per file**. bc-replay's `include` directive supports composition,
  but the workflow expects each `.yml` at an area root to be standalone so the
  matrix can report per-script pass/fail.
- **Custom extensions**: scripts that depend on custom extensions (PTEs or
  AppSource apps) should live in a dedicated area, so it is obvious which
  scenarios only run against environments where the extension is installed.
