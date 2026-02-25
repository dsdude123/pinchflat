# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Pinchflat is a self-hosted YouTube media manager built with Elixir/Phoenix. It uses yt-dlp to download content from YouTube channels and playlists on a schedule, with a Phoenix LiveView web UI. It runs as a single Docker container with SQLite for persistence.

## Commands

```bash
# Initial setup
mix setup

# Run all tests
mix test

# Run a single test file or specific test by line number
mix test test/pinchflat/sources/sources_test.exs
mix test test/pinchflat/sources/sources_test.exs:42

# Run the full check suite (formatter + credo + sobelow + prettier + tests)
mix check

# Run credo linter only
mix credo

# Run Prettier check / fix (JS, CSS, config files)
yarn run lint:check
yarn run lint:fix

# Database
mix ecto.migrate
mix ecto.reset

# Format Elixir code
mix format
```

The `mix check` alias reads `tooling/.check.exs` and the `mix credo` alias reads `tooling/.credo.exs`. Setting `EX_CHECK=1` enables warnings-as-errors during compilation.

## Architecture

### Directory structure

- `lib/pinchflat/` — business logic, organized as Phoenix contexts
- `lib/pinchflat_web/` — web layer (controllers, LiveView, router, plugs)
- `test/pinchflat/` — mirrors lib structure
- `test/support/` — test helpers, fixtures, mock scripts
- `config/` — per-environment config (`dev.exs`, `test.exs`, `prod.exs`, `runtime.exs`)
- `priv/repo/migrations/` — Ecto migrations

### Core contexts (`lib/pinchflat/`)

| Context | Purpose |
|---|---|
| `Sources` | YouTube channels/playlists being tracked |
| `Media` | Individual media items (videos) |
| `Profiles` | `MediaProfile` — reusable download quality/format settings |
| `Tasks` | Bridges Oban background jobs to Source or MediaItem records |
| `Downloading` | Media download workers and helpers; output path building |
| `SlowIndexing` | Full yt-dlp crawl of a source to index all media |
| `FastIndexing` | Quick check via YouTube RSS/API for new media only |
| `YtDlp` | Thin wrappers around yt-dlp commands (media, collections) |
| `Metadata` | Fetches/stores metadata and thumbnails for sources and media |
| `Lifecycle` | Apprise notifications and user lifecycle scripts |
| `Podcasts` | RSS feed generation for sources |
| `Settings` | App-level settings |
| `Boot` | Startup tasks run before/after Oban starts |

### Background job system

All async work uses **Oban** (backed by SQLite). Every Oban job is paired with a `Task` record that links the job to either a `Source` or `MediaItem`. Workers follow this pattern:

```elixir
# Create a job + task together
WorkerModule.kickoff_with_task(record, job_args, job_opts)

# The Tasks context manages lifecycle
Tasks.create_job_with_task(job_attrs, attached_record)
Tasks.delete_pending_tasks_for(record, "WorkerName")
```

Key workers:
- `MediaCollectionIndexingWorker` — slow indexing (full channel/playlist crawl via yt-dlp)
- `FastIndexingWorker` — fast indexing (RSS/YouTube API for recent videos)
- `MediaDownloadWorker` — downloads a single media item via yt-dlp
- `MediaQualityUpgradeWorker` / `MediaRetentionWorker` — redownload and cleanup

### Indexing flow

**Slow indexing** (`SlowIndexing`): Called on a schedule based on `index_frequency_minutes`. Runs yt-dlp against the source URL to get all media. Uses a `FileFollowerServer` GenServer to watch yt-dlp's output file and create `MediaItem` records in real time as they stream in.

**Fast indexing** (`FastIndexing`): Runs more frequently. Checks YouTube's RSS feed (or API if configured) for recent video IDs, creates `MediaItem` records for new ones, and immediately enqueues downloads.

### Backend abstraction / mocking

External executables (yt-dlp, apprise) are configured via `Application.get_env` so they can be swapped in tests:

```elixir
# config/config.exs — real runner
yt_dlp_runner: Pinchflat.YtDlp.CommandRunner

# config/test.exs — uses a shell script mock
yt_dlp_executable: Path.join([File.cwd!(), "/test/support/scripts/yt-dlp-mocks/repeater.sh"])
```

Use `Mox` to mock runner modules in tests. The pattern is:
```elixir
Application.get_env(:pinchflat, :yt_dlp_runner)  # fetched at call time, not compile time
```

### Testing conventions

- `DataCase` — use for tests that need DB access; sets up Ecto sandbox and Oban in manual mode
- `ConnCase` — use for controller/LiveView tests
- Fixtures live in `test/support/fixtures/` (e.g., `sources_fixtures.ex`, `media_fixtures.ex`)
- `TestingHelperMethods` provides `now/0`, `now_plus/2`, `now_minus/2`, `assert_changed/2`, `render_metadata/1`
- JSON fixture files are in `test/support/files/`
- Oban is set to `testing: :manual` — enqueue jobs explicitly in tests using `Oban.Testing`

### Frontend

- Tailwind CSS + esbuild; source in `assets/`
- Prettier is used for formatting all non-Elixir files (configured via `.prettierrc.js`)
- Phoenix LiveView for all interactive UI; websockets required (important for reverse proxy setups)

### Credo naming rule

`CredoNaming.Check.Consistency.ModuleFilename` enforces that module names match their file paths. This check is **disabled** for `lib/pinchflat_web/`, `test/support/`, `priv/`, and test web files — so the strict naming rule applies only to `lib/pinchflat/` and `test/pinchflat/`.
