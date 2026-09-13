# otp-rails-template

A `rails new` application template that puts a fresh Rails app under
[otp-rails](https://github.com/shishi-odoshi/otp-rails) supervision — and the
chaos tasks that prove it recovers.

```
rails new myapp -m https://raw.githubusercontent.com/shishi-odoshi/otp-rails-template/main/template.rb
```

## What it adds

- `gem "otp-rails"` (zero runtime dependencies; the supervisor never loads Rails)
- `config/supervisor.rb` — `rest_for_one` tree: `:web` (puma, health = HTTP `/up`
  probe) then `:jobs` (Solid Queue, health = active heartbeat)
- `bin/supervise` — run the tree; Ctrl-C drains children in reverse order
- `config/initializers/otp_rails_heartbeat.rb` — the jobs child heartbeats over
  the supervisor's Unix socket; a silent no-op when the app runs unsupervised
- `lib/tasks/chaos.rake`:

```
bin/supervise                      # in one terminal
bin/rails "chaos:kill[web]"        # SIGKILL puma; fails unless /up is back < 10s
bin/rails "chaos:kill[jobs]"       # SIGKILL solid queue; fails unless respawned < 10s
bin/rails chaos:all                # everything above in sequence
```

Restarting on purpose is the point: if recovery isn't boring, it isn't recovery.

**Queue ownership:** the generated `config/queue.yml` pins Ruby workers to `queues:
[default]` instead of Rails' `"*"` default. If you attach the Elixir job runner
([shishi-odoshi/beam](https://github.com/shishi-odoshi/beam)) on designated queues,
`"*"` would make Ruby workers silently race it — Solid Queue has no exclusion syntax,
so always enumerate Ruby-owned queues (see beam#10).

## CI

`scripts/verify.sh` (also the CI job) generates a brand-new app from
`template.rb`, boots it under `bin/supervise` in production env, runs every
chaos task asserting recovery under 10 seconds, and requires a clean exit-0
shutdown. The template is never allowed to drift from what it actually
generates.

Part of the [shishi-odoshi](https://github.com/shishi-odoshi) org. The design
lives in [otp-rails/docs/DESIGN.md](https://github.com/shishi-odoshi/otp-rails/blob/main/docs/DESIGN.md).
