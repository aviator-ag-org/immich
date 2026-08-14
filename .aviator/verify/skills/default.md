---
description: How to drive the Immich preview environment — signing in, the routes that matter, what counts as evidence in a photo app whose UI updates asynchronously, and which parts of Immich a preview cannot exercise.
---

# Verifying Immich in a preview

## What is actually running

One public port serves everything. The SvelteKit web app runs under `vite dev` on
port 3000 and proxies `/api`, `/.well-known/immich` and `/custom.css` (websockets
included) to the NestJS API on 2283. Postgres with pgvector and Redis run in the
same sandbox. Both web-side and server-side changes on the branch are live —
the server is compiled from branch source at launch, and Vite compiles web code
on demand, so nothing you see is a stale bundle.

## Signing in

The instance is already registered and onboarded, so you land on the login form,
not a setup wizard. Sign in at `/auth/login` with:

- Email: `{{ secrets.immich_username }}`
- Password: `{{ secrets.immich_password }}`

Despite the name, `immich_username` holds an **email address** — Immich has no
separate username; the login form's first field is an email.

This account is an **admin**, so `/admin/*` is reachable from the same session.
There is exactly one user unless your scenario creates more (`/admin/users`).

If you ever land on `/auth/register` or `/auth/onboarding`, the seed step did not
complete — treat that as a broken preview and report it rather than clicking
through the wizard, because the rest of the environment will not be in the state
described here.

## Seeded state

Six images are already in the library, uploaded with `fileCreatedAt` dates spread
across 2026-08-09 to 2026-08-12 so the timeline has more than one date group.
They are Immich's own logo and screenshot PNGs from `design/` and `web/static/`.

They are **synthetic library content, not photographs**: no GPS EXIF, no camera
metadata, no faces, no videos. Anything that depends on those is not verifiable
here — see the limits section.

## Routes worth knowing

| Route | What it is |
| --- | --- |
| `/photos` | Main timeline. Virtualized — scroll to load more, do not assume the DOM holds every asset |
| `/search` | Metadata/filename search |
| `/albums` | Album list and album detail |
| `/favorites`, `/archive`, `/trash` | Asset state views |
| `/sharing`, `/shared-links` | Partner sharing and public links |
| `/people`, `/places`, `/map`, `/explore` | Derived views (mostly empty here — see limits) |
| `/tags`, `/folders`, `/utilities`, `/memory` | Secondary browse views |
| `/user-settings` | Per-user preferences |
| `/admin/system-settings` | Server config editor |
| `/admin/users`, `/admin/jobs-status`, `/admin/queues` | Admin: users and background job state |
| `/admin/server-status` | Version, storage, server info |

## What counts as evidence here

Immich's UI is asynchronous in ways that make naive screenshots unreliable.

- **Wait for the thing, not for a timer.** Uploads, edits and deletions propagate
  over a websocket; the grid updates without a navigation. If a screenshot looks
  unchanged, re-check before concluding the change failed.
- **Derived media comes from background jobs.** A newly uploaded asset appears in
  the timeline before its thumbnail exists, showing a grey placeholder. That is
  the job queue, not a bug in the diff. `/admin/jobs-status` and `/admin/queues`
  show queue depth — check there before reporting a missing thumbnail.
- **Prefer the API for state claims, the UI for rendering claims.** Anything about
  what was persisted is better evidenced by a request to `/api/...` with the
  session token than by reading pixels. Anything about layout, styling or
  interaction needs the screenshot.
- **The timeline is virtualized.** "The asset is not in the DOM" is not evidence
  it is absent from the library. Scroll to it, or query the API.
- **Console noise is expected.** `vite dev` runs with HMR, so the console carries
  HMR websocket chatter, and disabled machine-learning features log failed job
  attempts. Neither is a defect introduced by the branch. Only treat console
  errors as evidence when they name code the diff touches.

## What a preview does NOT exercise

Do not write scenarios against any of these — they cannot pass here regardless of
whether the branch is correct.

- **The mobile app.** `mobile/` is Flutter and is not built or served. Nothing in
  this preview reflects a mobile change.
- **Machine learning.** Smart/CLIP search, face detection and recognition, and
  duplicate detection are disabled — no ML service runs in the sandbox. `/people`
  stays empty, and semantic search returns nothing useful. Metadata and filename
  search do work.
- **Map and places.** Seeded assets carry no GPS EXIF, so `/map` and `/places` are
  empty. Reverse geocoding itself is loaded and functional, so a scenario that
  uploads an asset with real GPS EXIF *can* work — but nothing pre-exists.
- **Video.** No video assets are seeded, and transcoding at any realistic scale is
  out of scope for a sandbox.
- **OAuth / OIDC login.** No identity provider is configured. Password login only.
- **Email.** No SMTP server, so anything that ends in a delivered message
  (invitations, password reset mail) stops at the send attempt.
- **External libraries and storage templates over real filesystems.** Storage is a
  scratch directory inside the sandbox with a handful of files.
- **Multi-user and partner-sharing flows out of the box.** Only one account is
  seeded; a scenario needing a second user must create it via `/admin/users`
  first.
- **Anything about upgrade or migration history.** The database is created fresh
  and migrated from empty at every launch.

## Public URL

The instance knows its own address: `PREVIEW_URL` is written into the server's
external-domain setting at launch, so generated share links point at the preview
rather than at `localhost`. If you are checking share-link behaviour, that is the
setting involved, visible under `/admin/system-settings`.
