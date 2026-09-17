<!-- Base branch should be `dev`. Delete any section that does not
     apply - an empty heading is noise. -->

## What changed

<!-- One paragraph. The diff is below; do not narrate it. Say what this makes
     possible, or what it stops happening. -->

## Why

<!-- Closes #123. If there is no issue, say what broke or what was missing. -->

## Build output

<!-- The tail of the gate, with the real numbers. This is not proof that it
     ran - the pre-push hook would have blocked you otherwise - it is so the
     reviewer can see coverage and test counts without checking out. -->

    $ docker compose config --quiet && docker compose up -d
    $ docker compose ps

    NAME                          STATUS
    homecrew-postgres             Up (healthy)
    homecrew-kafka                Up (healthy)
    homecrew-service-discovery    Up (healthy)
    ...

<!-- Paste the real table. Every container must reach `healthy`, not just
     `running` - a container that is up but not yet healthy refuses
     connections and the services behind it fail to start. -->

## Failures and warnings

<!-- There is no build log here. Say what went wrong, what you skipped, and
     what you decided about it - a container that would not come up, a value
     that did not take effect, a warning you are living with. "None" is a
     real answer and a useful one. -->

## Impact

<!-- Tick only what applies. Nothing the hooks already enforce is listed here:
     formatting, Checkstyle, SpotBugs, coverage, secrets, branch name and
     commit format are all green or this branch could not have been pushed. -->

- [ ] New or changed environment variable - also in `.env.example`, and set
      on the Hetzner host before this merges
- [ ] Database added or changed in `postgres/init/` - note that the init
      script runs only on an empty volume, so an existing stack needs the
      database created by hand or `docker compose down -v`
- [ ] Port, image name or healthcheck changed
- [ ] New service - added to compose, to the deploy allow-list in
      `.github/workflows/deploy.yml`, and to the init script if it needs a
      database
- [ ] `deploy.yml` changed - say below how you tested it, since a broken
      deploy workflow is only discovered on the next service push
- [ ] Memory limit or JVM flag changed - the host is small and the budget is
      shared
- [ ] README updated - topology, ports or setup changed
- [ ] None of the above; this is self-contained

## Risk

<!-- Blast radius. Which services break if this is wrong, what has to land
     first, and how you would roll it back. "None, additive" is a useful
     thing for a reviewer to read. -->
