<!-- Delete any section that does not apply. An empty heading is noise. -->

## What changed

<!-- One paragraph. The diff is below; do not narrate it. Say what this makes
     possible, or what it stops happening. -->

## Why

<!-- Closes #123. If there is no issue, say what broke or what was missing. -->

## How to verify

    docker compose config --quiet
    docker compose up -d
    docker compose ps

Every container must reach `healthy`, not just `running`. Paste the `ps`
output if anything changed in the topology.

## Checklist

- [ ] Base branch is `dev`
- [ ] Branch name is `dev__YYYYmmDD__lower_snake_name`
- [ ] Every commit subject is Conventional Commits, 100 characters or fewer
- [ ] `docker compose config --quiet` parses cleanly
- [ ] The whole stack comes up locally and every healthcheck reaches `healthy`
- [ ] No secrets added - `.env` is gitignored and no hook runs here, so this
      one is on you
- [ ] New ports do not clash with the 8080-8089, 8761, 8888, 5432, 9092 range
- [ ] `.env.example` updated if a new variable is required
- [ ] `postgres/init/01-create-databases.sql` updated if a service gained a
      database
- [ ] The deploy allow-list in `.github/workflows/deploy.yml` covers any new
      service
- [ ] README updated if behaviour, ports or setup changed

## Risk

<!-- Blast radius. Which services break if this is wrong? Does a config or
     compose change have to land first? Say "none, additive" if that is true -
     it is a useful thing for a reviewer to read. -->
