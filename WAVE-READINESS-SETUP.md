# Setting Up Wave Readiness Validation

Everything needed to go from an empty repository to a green run that replays
your business processes against the next Business Central update. Written so
you do not need to be an expert in Entra, Azure or GitHub Actions — each phase
says what you are doing, why, and how to tell it worked before you move on.

**Plan on 1–2 hours.** The Entra app and the report website are the slow parts;
the rest is paste-and-go. You do not have to finish in one sitting. The
architecture is in [README.md](README.md); this file is the procedure.

---

## 0. Read this first

### The idea in one paragraph

Microsoft updates Business Central twice a year, plus monthly service updates.
Normally you find out whether those updates break your business processes when
your users hit them. This changes that: a copy of your production company is
made into a throwaway sandbox, that sandbox is upgraded to the new version
**early**, and a robot then clicks through your real processes — creating a
purchase order, posting an invoice, running a payment journal — to see whether
they still work. You get a report with screenshots and video before the update
reaches anyone.

### The one thing it destroys

> [!WARNING]
> **Every run deletes and recreates the sandbox named by `BC_TARGET_ENV`.**
> It is copied fresh from `BC_SOURCE_ENV` (your production), then optionally
> upgraded. Point `BC_TARGET_ENV` at a throwaway sandbox and nothing else. If
> you name a sandbox somebody relies on, its contents are gone on the next run.

Your **production environment is only ever read** — the BC admin API copies
from it. Nothing is written back.

### What it costs

- **~US$13/month** for a small Azure web server that hosts the report. This is
  the only recurring cost.
- **GitHub Actions minutes.** A full run is 45–60 minutes of `ubuntu` and
  `windows` time, and Windows minutes bill at a higher multiplier. A weekly run
  sits comfortably inside a Team plan's included minutes.
- **One Business Central licence** for the user that does the clicking.

### Access you will need

You may need to ask colleagues for some of these. Gather them before you start
rather than stalling halfway.

| You need to be | Where | Used for |
|---|---|---|
| Application Administrator | Microsoft Entra | Creating the app (phase 4) |
| Global Administrator, or able to ask one | Microsoft Entra | Granting consent (phase 4) |
| Internal Administrator | BC admin centre | Authorising the app, managing environments |
| Owner, or Contributor + User Access Administrator | Azure subscription | The report website (phase 7) |
| Admin on the repository | GitHub | Phases 2, 3 and 9 |
| Able to manage users and permissions | Business Central | Phases 5 and 6 |

### Your repository must be private, on a paid plan

> [!IMPORTANT]
> The repository must be **private**, and that means a paid GitHub plan:
> **GitHub Team**, Pro, or Enterprise. The free plan does not offer deployment
> environments on private repositories, and this pipeline deploys through an
> environment named `report-site` — without it, every run fails at once.
>
> **Making the repository public to avoid that cost is not an option.** Your
> recordings describe how your business works, and the reports contain
> screenshots and video of your live Business Central — real vendors, real
> customers, real prices. Publishing that is a data leak, not a shortcut.
> Budget for the plan before you begin.

### What gets added to your repository

| Added | Notes |
|---|---|
| `.github/workflows/WaveReadinessValidation.yaml` | Runs on manual trigger only; never on push or PR |
| `.github/workflows/UpdateWaveReadiness.yaml` | Weekly self-update; inert until you give it a token (phase 12) |
| `.github/actions/`, four files under `.github/scripts/` | Helper pieces. Anything else you keep there is untouched |
| `WAVE-READINESS-SETUP.md` | This guide |
| `PageScriptLibrary/` | Empty skeleton; yours to fill |
| `.pipeline-version` | Records which version you installed |
| A `report-site` deployment environment | The deploy target |
| A `wave-readiness-history` branch | Created on first run; holds the rolling report history |

If any of those paths already exist, the installer stops and lists them rather
than overwriting. Nothing else in your repo is read or modified.

### Phase map

Work top to bottom. Each phase ends with a check; do not move on until it
passes, because a mistake in an early phase surfaces as a confusing failure
several phases later.

| # | Phase | Where | Time |
|---|---|---|---|
| 1 | Install the tools | Your computer | 15 min |
| 2 | Prepare the repository | GitHub | 5 min |
| 3 | Install the pipeline | Terminal | 2 min |
| 4 | Permission to manage environments | Entra + BC admin centre | 20 min |
| 5 | The replay user | BC + M365 admin | 15 min |
| 6 | The Page Scripting role | Business Central | 5 min |
| 7 | The report website | Terminal | 10 min |
| 8 | Teams notifications *(optional)* | Teams | 10 min |
| 9 | Store the settings | Terminal | 10 min |
| 10 | Record your processes | Business Central | Open-ended |
| 11 | First run | GitHub | 45–60 min, mostly waiting |

---

## 1. Install the tools

Five free programs on your own computer. You only do this once.

| Tool | What it's for | Get it from |
|---|---|---|
| Node.js 18+ | Runs the installer | [nodejs.org](https://nodejs.org) — take the LTS version |
| PowerShell 7+ | The installer is written in it | [Microsoft](https://learn.microsoft.com/powershell/). The "Windows PowerShell" already on your PC is version 5 and is **not** enough |
| Git | Talks to your repository | [git-scm.com](https://git-scm.com) |
| GitHub CLI | Stores settings in your repository for you | [cli.github.com](https://cli.github.com) |
| Azure CLI | Builds the report website for you | [Microsoft](https://learn.microsoft.com/cli/azure/install-azure-cli) |

Sign in to the two that need it:

```bash
gh auth login
az login
```

Each opens a browser window. Sign in with the account that has the access
listed in phase 0.

> [!TIP]
> **Check it worked.** Run each of these. Every one should print a version
> number or an account name, not an error.
>
> ```bash
> node --version
> pwsh --version
> git --version
> gh auth status
> az account show
> ```

---

## 2. Prepare the repository

A GitHub repository is where the automation lives. Any repository works — it
can be one you already use.

If you do not have one, create a new empty repository and set its visibility to
**Private**. If you are adding this to an existing repository, confirm that one
is private too.

Get a copy on your computer:

```bash
git clone https://github.com/YOUR-ORG/YOUR-REPO.git
cd YOUR-REPO
```

`git clone` creates a folder named after the repository; the `cd` line moves
into it. **Everything from here on runs inside that folder**, not the one you
ran `git clone` from.

> [!TIP]
> **Check it worked.** Inside the folder, `git remote -v` prints your
> repository's GitHub address twice. If it prints nothing, you are in a folder
> that was created with `git init` rather than in the clone — perhaps one
> level above it. The installer needs the clone: it is how the settings and
> the deploy environment find your repository on GitHub.

---

## 3. Install the pipeline

One command, run from the **root of the repository**.

First check your machine has everything:

```bash
npx @inmindtechnologies/bc-wave-readiness doctor
```

Every line should say `ok`, and the **GitHub repository** line should name
your repository. If that line says `MISSING`, you are not inside the clone —
go back to phase 2 before installing anything.

Then install:

```bash
npx @inmindtechnologies/bc-wave-readiness
```

The first time, `npx` asks *"Need to install the following packages … Ok to
proceed?"* — that is it fetching the installer, not changing your repository.
Answer `y`. Nothing is written until it starts listing each file it copies.

When it offers to set up Azure and the settings wizard, answer **n** to both
for now — you do not have those values yet. You come back in phases 7 and 9.

If this `WAVE-READINESS-SETUP.md` is already in the repository because you fetched it with
`npx @inmindtechnologies/bc-wave-readiness guide`, that is fine, even if a
newer version has been released since: the installer recognises the guide as
its own and replaces it with the current one. It refuses only when one of the
*other* files it manages already exists with different content, because that
could be something of yours.

Save the files into your repository:

```bash
git add -A
git commit -m "Add wave readiness pipeline"
git push
```

> **Why `npx` and not a committed script.** `setup-pipeline.ps1` is not one of
> the pipeline's managed files, so a copy committed into your repo is frozen at
> install time and never receives a fix — `update` refreshes the pipeline, not
> the installer. `npx` resolves the current published version every time.
>
> The package carries the workflow, the composite actions and the helper
> scripts, so installing needs no access to the source repository. `gh` is used
> only against **your own** repository.

> If the install stops at once saying there is **no GitHub remote here**, you
> are not inside the clone. Nothing was written. Move into the clone (phase 2)
> and run `doctor` again before installing.

> [!TIP]
> **Check it worked.** On GitHub, the **Actions** tab now lists a workflow
> called **Wave Readiness Validation**. Do not run it yet — it has nothing to
> work with.

---

## 4. Permission to manage environments

The automation needs permission to copy and upgrade your Business Central
sandboxes. That permission is granted to an *app registration* — an identity
for a program rather than a person.

### 4.1 Create the app

1. Go to [entra.microsoft.com](https://entra.microsoft.com) → **Applications**
   → **App registrations** → **New registration**.
2. Name it something recognisable, e.g. `BC Wave Readiness`. Leave the other
   options as they are. Click **Register**.
3. On the overview page, copy the **Application (client) ID** and the
   **Directory (tenant) ID**. You need both in phase 9.
4. Go to **API permissions** → **Add a permission** → **APIs my organization
   uses** → search for **Dynamics 365 Business Central**.
5. Choose **Application permissions** (not Delegated), tick
   **AdminCenter.ReadWrite.All**, and add it.
6. *Only if you want email notifications:* add **Microsoft Graph** →
   **Application permissions** → **Mail.Send** as well.
7. Click **Grant admin consent** and confirm. If that button is greyed out, a
   Global Administrator has to press it — the permission does nothing until
   they do.
8. Go to **Certificates & secrets** → **New client secret**. Set an expiry you
   will remember to renew. Copy the **Value** immediately.

> [!CAUTION]
> The secret **Value** is visible only right after you create it. Navigate away
> and it is gone forever — you would have to make a new one. Note the expiry
> date somewhere too: when it lapses, runs start failing with an authentication
> error that does not mention expiry.

### 4.2 Authorise the app in Business Central

1. Go to the [BC admin centre](https://businesscentral.dynamics.com/admin).
2. Open **Settings** → **Microsoft Entra apps** (older tenants: **Azure Active
   Directory apps**) → **New**.
3. Paste the **client ID** from 4.1, give it a description, and set **State**
   to **Enabled**.

You should now have three things written down: **tenant ID**, **client ID**,
**client secret**.

> [!TIP]
> **Check it worked.** In Entra, open your app → **API permissions**. The row
> for `AdminCenter.ReadWrite.All` shows a green tick and **Granted for [your
> organisation]**. If it says "Not granted", consent was not completed and
> phase 11 fails with a 403.

---

## 5. The replay user

A real Business Central user account. The robot signs in as this person and
clicks through your processes, so it must be able to sign in exactly as a human
would. Application users cannot do this — the web client requires an
interactive sign-in.

> [!IMPORTANT]
> Create this user in your **production** environment — the one you copy
> *from*. The sandbox is built by copying production, so anything that exists
> only in the sandbox is wiped on the next run. This applies to everything in
> phases 5 and 6.

1. Create a normal user account (for example `bcreplay@yourcompany.com`) and
   give it a Business Central licence — Essentials or Premium, either is fine.
2. In Business Central, search for **Users** and confirm the account appears.
   If not, use **Update Users from Microsoft 365**.
3. Assign the permission set **PAGESCRIPTING-PLAY**. This ships with Business
   Central; if it is not present, import it from **System** → **Permission
   Sets**. Without it every recording fails immediately.
4. Also assign whatever permissions your processes need — for example
   `D365 PURCH DOC, POST` for purchasing flows. If in doubt, mirror the
   permissions of a user who does this work today.
5. Sort out multi-factor authentication — see below.

### Multi-factor authentication: pick one, exactly

The robot cannot tap "Approve" on a phone. You have two workable options, and
choosing the wrong combination is a common cause of failure.

| Option | What to do | In phase 9 |
|---|---|---|
| **No MFA** — simplest | Exclude this account from your conditional access / MFA policy. Suitable for a non-production robot account; discuss with whoever owns security policy | Do **not** set `BC_REPLAY_TOTP_SECRET` |
| **MFA by authenticator code** | Add a TOTP method to the account and keep the setup key — the long string behind the QR code | Set `BC_REPLAY_TOTP_SECRET` to that key |

> [!CAUTION]
> **Do not mix them.** If you provide a TOTP secret but sign-in never actually
> asks for a code, every recording fails with
> `The MFA field is not visible!` — the robot waits for a box that never
> appears. Push-notification or phone-call MFA will not work at all; it must be
> an authenticator code, or nothing.

> [!TIP]
> **Check it worked.** Open a **private browser window** and sign in to
> Business Central as this user. You should reach a normal role centre with no
> approval prompt on your phone, no "welcome" tour, and no consent dialog.
> Anything that interrupts *you* here will interrupt the robot too — and it
> shows up as an unexplained timeout rather than a clear login error.

---

## 6. The Page Scripting role

Every recording declares which role centre it starts from. That role must
exist in the environment, or recordings hang and time out before running a
single step.

Business Central calls these *profiles* in the admin pages and *roles* in the
user interface. They are the same thing.

1. In your **production** environment, search for **Profiles (Roles)**.
2. Click **New**.
3. Set **Profile ID** to `PAGE SCRIPTING`.
4. Set **Display Name** to `Page Scripting`.
5. Set **Role Center ID** to `9022` (Business Manager). Any valid role centre
   works — the recordings do not depend on which.
6. Tick **Enabled**.

The display name matters: when a recording starts, it searches the available
roles list for that text. If nothing matches, it waits two minutes and gives up.

> If your recordings were made starting from a different role, use that role's
> ID and name instead. The rule is simply that the role named inside your
> `.yml` files must exist in the environment. Keeping every recording on one
> role is much easier to maintain.

> [!TIP]
> **Check it worked.** Sign in as the replay user, open **My Settings**, click
> the **Role** field's lookup, and type `Page Scripting`. Exactly one row
> should appear. If the list comes back empty, phase 11 hangs.

---

## 7. The report website

Results are published to a small private website so colleagues can read them
from a link. One command builds the whole thing — this is the part that would
otherwise be a long slog through the Azure portal.

```bash
npx @inmindtechnologies/bc-wave-readiness provision
```

It asks five questions, each with a sensible default already filled in — press
**Enter** to accept each one unless you have a reason not to:

- **Tenant** and **subscription** — taken from the account you signed into with
  `az login`
- **Region** — where the website lives; pick one near your users
- **Resource group** — the folder Azure keeps it all in
- **Web app name** — must be unique across all of Azure, so it may need a tweak

It then creates the website, protects it with Entra Easy Auth so only people in
your organisation can open it, creates the identity GitHub uses to publish to
it, and writes the resulting settings into your repository automatically. You
do not need to copy anything down.

Add `--dry-run` to see what it would do without doing it.

> **Who may see the reports.** Easy Auth admits anyone in your tenant by
> default. To narrow it, restrict the allowed audience on the identity provider
> of the `BC Wave Reports - …` app registration.

> [!TIP]
> **Check it worked.** It finishes by printing a URL. Open it. You should be
> asked to sign in with your work account — *being asked is the success case*.
> It means the site exists and is private. There is no report in it yet.

---

## 8. Teams notifications *(optional)*

Skip this whole phase if you do not want Teams messages on failure. Email
notifications work without it.

1. In the target Teams channel: **+** (add tab) → **Workflows** → choose
   **Post to a channel when a webhook request is received**.
2. Pick the team and channel → **Next** → **Add workflow** → copy the resulting
   URL.
3. Save it as the `TEAMS_WEBHOOK_URL` secret in phase 9.

The workflow posts an adaptive card payload as-is; the default "Post to
channel" action forwards the request body directly, which is what we need.

---

## 9. Store the settings

Passwords go into GitHub's encrypted secret store, never into files.

Use the wizard rather than the GitHub UI:

```bash
npx @inmindtechnologies/bc-wave-readiness configure
```

It walks every value below one at a time, and it is worth using over pasting by
hand because it:

- **says where each value came from** — "from: phase 4 step 3" — so you are not
  matching names to notes;
- **validates the two that fail late**: a report URL missing its trailing slash
  is rejected on the spot rather than 404ing after a 45-minute run, and a
  mistyped GUID is caught before it becomes an auth error that names none of
  the six IDs it could be;
- **warns before `BC_TARGET_ENV`**, which is deleted and recreated every run;
- **lets you replace a value you already set.** Press Enter to keep the current
  one. Values already present are marked `[set]`.

It creates the `report-site` environment too, and finishes by naming any
required value still missing.

To set them by hand instead: Repository → **Settings** → **Secrets and
variables** → **Actions**.

### Secrets — encrypted, never shown again

| Name | Source | Required |
|---|---|---|
| `BC_ADMIN_TENANT_ID` | Phase 4, step 3 | Yes |
| `BC_ADMIN_CLIENT_ID` | Phase 4, step 3 | Yes |
| `BC_ADMIN_CLIENT_SECRET` | Phase 4, step 8 | Yes |
| `BC_REPLAY_USER` | Sign-in address of the phase 5 user | Yes |
| `BC_REPLAY_PASSWORD` | That user's password | Yes |
| `BC_REPLAY_TOTP_SECRET` | Authenticator setup key | **Only** if that user is genuinely prompted for a code |
| `AZURE_DEPLOY_CLIENT_ID` | Written by phase 7 | Yes |
| `AZURE_DEPLOY_TENANT_ID` | Written by phase 7 | Yes |
| `AZURE_DEPLOY_SUBSCRIPTION_ID` | Written by phase 7 | Yes |
| `TEAMS_WEBHOOK_URL` | Phase 8 | Optional |

### Variables — plain settings, visible to your team

| Name | Source | Required |
|---|---|---|
| `AZURE_WEBAPP_NAME` | Written by phase 7 | Yes |
| `REPORT_SITE_URL` | Written by phase 7 (trailing slash required) | Yes |
| `BC_SOURCE_ENV` | Environment to copy *from*, e.g. `Production`. Name it exactly as the BC admin centre shows it | Yes |
| `BC_TARGET_ENV` | The throwaway sandbox, e.g. `SANDBOX-Waves` | Yes |
| `NOTIFY_FROM` | Mailbox in your tenant for outbound notifications | Only for email |
| `NOTIFY_TO` | Mailbox to receive the notification email | Only for email |
| `BC_ADMIN_API_BASE` | Override the admin API URL | Only if Microsoft retires `v2.28` |

> [!WARNING]
> `BC_TARGET_ENV` does not need to exist yet — the copy creates it. Naming an
> environment that *does* exist, and that someone uses, means losing its
> contents on the first run. Pick a name nobody will recognise as theirs.

> [!TIP]
> **Check it worked.** On GitHub: **Settings → Secrets and variables →
> Actions**. You see your BC secrets plus three `AZURE_DEPLOY_*` ones, and your
> variables on the second tab.

---

## 10. Record your processes

This is the part only you can do — nobody else knows what your business
actually does. It is also the part that decides whether any of this is useful.
The library ships empty on purpose.

### Make a recording

1. Sign in to Business Central as a user with the **Page Scripting** role.
2. Open the Page Scripting pane (**Settings** gear → **Page Scripting**).
3. Press **Record**, then carry out the process exactly as a user would —
   create the purchase order, receive it, post the invoice.
4. Press **Stop**, then **Save**, then **Download**. You get a `.yml` file.

See `PageScriptLibrary/README.md` for the full recording guide and
data-stability tips.

### Where the files go

Put each file inside `PageScriptLibrary/`, in a folder named `Area - N`. The
number sets the running order.

```text
PageScriptLibrary/
  MasterData - 1/    ← always runs first
  Purchase - 2/
  Invoice - 3/
  Return - 4/
  Payment - 5/
```

- `MasterData - 1/` is **reserved**. It runs first, on its own job, and its
  failure blocks every later area by design.
- Other folders run sequentially in folder-name sort order. The numeric suffix
  controls the order.
- Inside each folder, scripts run in file-name sort order.

**`MasterData - 1` should create what your other recordings depend on** — the
vendors, items and posting setup. The sandbox is a fresh copy of production
each run, so anything a later recording needs must either already exist in
production or be created here.

### Two rules that save a lot of pain

- **Every recording should start from the same role** — the one from phase 6.
  Mixed roles mean a recording that works today breaks when one role changes.
- **Do not depend on data you did not create.** A recording that opens
  "invoice 12345" works until that invoice is not there.

Commit and push them:

```bash
git add PageScriptLibrary
git commit -m "Add page script recordings"
git push
```

> [!TIP]
> **Check it worked.** On GitHub, browse into `PageScriptLibrary/` and confirm
> your `.yml` files are there inside their area folders. If the library is
> empty, the run in phase 11 finishes in about 20 seconds, reports success, and
> tests nothing at all.

---

## 11. First run

Everything is in place. This takes 45–60 minutes, most of it waiting.

1. Confirm **Actions** are enabled: Settings → Actions → General.
2. Go to **Actions** → **Wave Readiness Validation** → **Run workflow**.
3. For your **first** run, tick **skipUpgrade** and leave **refreshSandbox**
   ticked. This proves the copy and replay path works before adding an upgrade
   to the picture.
4. Press the green **Run workflow** button.

### The options explained

| Option | What it does |
|---|---|
| `targetVersion` | `latest` upgrades to the newest available version — usually the next wave's preview. You can also give a specific one like `28.5` |
| `skipUpgrade` | Skip upgrading and replay against the current version. **Recommended for the first run** |
| `refreshSandbox` | Leave ticked. Unticking reuses the existing sandbox and saves ~10 minutes when iterating on recordings |
| `scriptArea` | Leave blank to run everything, or name one folder to run only that |

### What you will see

| Job | Expect |
|---|---|
| `setup` | Seconds. Checks the Azure connection and finds your recordings |
| `copy-and-upgrade` | 8–15 minutes to copy, plus up to 35 more if upgrading |
| `master-data`, then `replay` | Roughly 20–45 seconds per recording |
| `deploy-report`, `notify` | A minute or two |

The `setup` job also smoke-tests the Azure deploy identity. If that fails it
does **not** stop the run — replay still happens and results still upload as
artifacts — but the summary warns the report will not publish, and prints the
exact federated-credential subject to add. Fix it while replay is still
running.

> [!TIP]
> **Check it worked.** The run finishes green and your report URL from phase 7
> now shows results, with video and screenshots for each recording. If anything
> failed, go to phase 13 — and do not trust the first error message you see.

---

## 12. Keeping it running

### Routine

| When | Do this |
|---|---|
| A wave preview drops | Run with `targetVersion: latest` and find out what breaks while you still have months to react |
| A new business flow needs coverage | Record it, drop the `.yml` into the matching area folder, open a PR — the workflow discovers it next run |
| Dependabot opens a **CI** PR | It is bumping the pinned GitHub Actions. Merge, then run once with `skipUpgrade=true` to confirm the pipeline still passes |
| A recording breaks | An issue auto-opens naming it. Open the report, watch the video, find the broken step, re-record with `refreshSandbox=false`, commit the new `.yml` |
| Updates are published upstream | `npx @inmindtechnologies/bc-wave-readiness update`, review with `git diff`, commit |

Running `update` before spending an hour debugging is worth it — several
failure modes are simply older versions.

### Letting the repo update itself

The install includes `.github/workflows/UpdateWaveReadiness.yaml`, which does
the same re-sync weekly and opens a pull request with the diff. It is **inert
until you give it a token**, and it never pushes to a default branch.

Why a token: GitHub does not allow the built-in `GITHUB_TOKEN` to modify files
under `.github/workflows/`, and the pipeline's own workflow is one of the files
an update rewrites.

To enable it, create a fine-grained PAT scoped to this repository with
**Contents: Read and write**, **Pull requests: Read and write** and
**Workflows: Read and write** (a classic PAT with `repo` + `workflow` also
works), then save it as the repository secret `UPDATE_TOKEN`.

Without the secret the workflow still runs weekly and writes a job summary
explaining how to enable it. It never fails, so it cannot turn the Actions tab
red on a repo that never opted in.

> **What an update can and cannot change.** It rewrites only the pipeline's
> managed files. Your GitHub secrets, your repository variables and everything
> under `PageScriptLibrary/` are outside that set, so no update can undo your
> configuration or touch your recordings.

### Calendar items

Two credentials expire and take the pipeline down the morning they do:

| Item | Symptom when it lapses | Fix |
|---|---|---|
| Entra client secret (phase 4) | Every run fails with **401** from the BC admin API | New secret → update `BC_ADMIN_CLIENT_SECRET`. Set a reminder ~6 weeks before expiry |
| Replay user password | `master-data` fails at sign-in | Update `BC_REPLAY_PASSWORD` — nothing else moves |

### Removing everything

```bash
az group delete --name YOUR-RESOURCE-GROUP --yes
```

Then delete the two app registrations in Entra (`GH Deploy - …` and
`BC Wave Reports - …`), and delete the throwaway sandbox in the BC admin
centre. The Azure resource group is the only thing costing money, so delete
that first.

---

## 13. When something fails

Read this before you start changing things. The most common mistake is fixing
the wrong problem.

### Look in the right place first

> [!IMPORTANT]
> The GitHub log often shows a message that is **not** the real cause — a
> passing network error, or nine recordings "failing" for one shared reason.
> The truth is in the test results attached to the run.
>
> Open the run on GitHub, scroll to **Artifacts** at the bottom, download
> `replay-results`, and open `results.xml` for a failing recording. It names
> the actual error. Next to it, `error-context.md` describes what was on screen
> at the moment it gave up — which usually makes the cause obvious.

### Errors you are likely to meet

| What you see | What it means | Fix |
|---|---|---|
| `The MFA field is not visible!` | A TOTP secret is configured, but sign-in never asks for a code | Delete the `BC_REPLAY_TOTP_SECRET` secret — phase 5 |
| `Playback is not allowed. The user does not have the required system permission 'Allow Page Scripting Playback'.` | The replay user is missing a permission set | Assign `PAGESCRIPTING-PLAY` in **production**, then re-run with `refreshSandbox` ticked |
| One recording hangs ~2 min then fails; the snapshot shows *"Available Roles now has 0 items"* | The role that recording starts from does not exist | Create it in production — phase 6 — then re-run with `refreshSandbox` ticked |
| Every recording fails in seconds, all with the same message | Almost never the recordings. Something shared: sign-in, permissions, or the role | Fix the one shared cause; do not edit the recordings |
| `Modifying ScheduleDetails for updates with available=false is not supported` | Older pipeline version mis-selecting the upgrade target | `npx … update` |
| `Download failed: server closed connection … chromium` | Older pipeline version; the browser was not installed up front | `npx … update` |
| **403** from the BC admin API in `copy-and-upgrade` | The Entra app was never authorised in the BC admin centre, or the entry was removed | Re-add it: phase 4.2. Confirm **State: Enabled** |
| **401** from the BC admin API | Client secret expired, or `BC_ADMIN_CLIENT_SECRET` is stale | New secret, update the GitHub secret |
| Run summary warns **deploy identity unusable** | Azure does not trust this repository. Results are still produced — only the published report is lost | The summary prints the exact subject expected. Copy it **verbatim** into the Entra app's federated credential. Do not retype it from memory |
| `Update failed … extension '…' failed to synchronize the database schema` | The new BC version genuinely cannot install on your data — often a Microsoft-supplied extension. Your environment is rolled back automatically | Not something you can fix. **This is the pipeline doing its job** — raise it with Microsoft support, well before the version goes live |
| `setup` reports `hasScripts=false`, run ends in ~20s "successfully" | No recordings were found, so nothing was tested | Area folders must sit directly under `PageScriptLibrary/` with `.yml` at their root — not nested deeper |
| Run sits at the very first step doing nothing | Someone added required reviewers to the `report-site` environment | Approve it in the Actions tab, or remove the reviewer rule under **Settings → Environments** for unattended runs |
| Report site returns 404 after a successful deploy | `REPORT_SITE_URL` is wrong | It must end with a **trailing slash** |
| Recordings pass individually but fail in a full run | They depend on data a `MasterData - 1` recording creates, and that one failed | Fix the master-data recording first |

### The rule that explains most surprises

> [!IMPORTANT]
> Permissions, roles and app authorisations live **inside** an environment.
> Changing them in production does **not** affect a sandbox that already
> exists. The sandbox only picks them up when it is rebuilt — a run with
> `refreshSandbox` ticked.
>
> This catches people out in a confusing way: a fix in production appears to do
> nothing, or a rebuild appears to *break* something that worked — because the
> sandbox had a setting applied directly to it that production never had.

---

## 14. Configuration reference

The values most likely changed during adoption. If something stops behaving,
start here.

| Where | What | Default |
|---|---|---|
| Workflow `env:` (overridable via vars) | `SOURCE_ENV` | `PRODUCTION` |
| Workflow `env:` (overridable via vars) | `TARGET_ENV` | `SANDBOX-Waves` |
| Workflow `env:` (overridable via vars) | `ADMIN_API_BASE` | `…/admin/v2.28/applications/BusinessCentral` |
| Workflow `env:` (fixed) | `MASTER_DATA_AREA` | `MasterData - 1` |
| Workflow `env:` (overridable via vars) | `NOTIFY_FROM` / `NOTIFY_TO` | *(unset — email skipped)* |
| `build-report-site.sh` env | `MAX_RUNS` | `7` |
| `setup-bc-replay` input | `node-version` | `24` |

The workflow falls back to the placeholder defaults `PRODUCTION` and
`SANDBOX-Waves` when a variable is unset. Set both to your real environment
names before running.

---

## 15. Renaming, transferring, or forking the repository

The federated credential's subject is **read from GitHub** rather than built
from your owner and repo name. GitHub issues one of two forms, and which one a
repository gets is not something you choose: the plain
`repo:Acme/Reports:environment:report-site`, or one that embeds numeric entity
IDs — `repo:Acme@123/Reports@456:environment:report-site` — so that the claim
**survives a rename**. Entra matches the string exactly, so a subject typed
from memory in the wrong form matches nothing. `provision` asks GitHub which
form applies and uses that; if you ever set the credential by hand, copy the
subject from the `setup` job summary rather than composing it.

So a rename may or may not break deployment, depending on which form your
repository has. A **transfer to a different organisation** can break either
form. Either way the fix is the same checklist:

Checklist after a rename or transfer, in order:

1. **Recreate the `report-site` environment.** Environments do not always
   survive a transfer, and the destination org's plan must support them on a
   private repo (GitHub Team, Pro or Enterprise). Quickest:
   `npx @inmindtechnologies/bc-wave-readiness configure`.
2. **Update the federated identity credential.** Run the workflow once: the
   `setup` preflight prints the exact subject Entra must trust within ten
   seconds. Copy that value onto the deploy app — do not reconstruct it.
3. **Check the destination org's Actions policy.** This workflow pins every
   action to a commit SHA. Some allowlist configurations match on
   `owner/repo@ref` and will not match a SHA pin; allow `actions/*`, `azure/*`,
   or the specific SHAs. Confirm the default `GITHUB_TOKEN` permissions are not
   locked below what `deploy-report` requests (`contents: write`,
   `issues: write`, `id-token: write`).
4. **Verify secrets and variables survived**: `gh secret list`,
   `gh variable list`.
5. **Update local clones**:
   `git remote set-url origin https://github.com/NewOrg/NewName.git`.
6. **Smoke-test** with `skipUpgrade=true`.

> **Forking rather than transferring?** A fork is a different repository, so it
> needs its own federated credential, its own `report-site` environment, and
> its own secrets — GitHub does not copy secrets to forks. Treat it as a fresh
> adoption and work through this guide from phase 1.

---

## 16. Plain-English glossary

| Term | What it actually means here |
|---|---|
| **Wave** | One of Microsoft's twice-yearly major Business Central updates |
| **Environment** | One copy of Business Central — your production system, or a sandbox |
| **Sandbox** | A non-production copy. Safe to break; this is what gets rebuilt each run |
| **Tenant** | Your organisation's Microsoft account, identified by a long code |
| **Entra** | Microsoft's identity service. Used to be called Azure Active Directory |
| **App registration** | An identity for a program rather than a person, so automation can sign in |
| **Client secret** | That identity's password. Expires; shown only once |
| **Permission set** | A named bundle of Business Central permissions given to a user |
| **Profile / Role** | The layout a user sees on sign-in. Two names for one thing |
| **Page script** | A recording of someone using Business Central, saved as a `.yml` file |
| **Workflow / Actions** | GitHub's automation. "Actions" is the tab; a "workflow" is one automated job |
| **Secret** | An encrypted value stored in GitHub. Can be written, never read back |
| **Easy Auth** | Azure's built-in sign-in wall, used to keep the report private |
| **OIDC / federated credential** | How GitHub proves its identity to Azure without a stored password |
