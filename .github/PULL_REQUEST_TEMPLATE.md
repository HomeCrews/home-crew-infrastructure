<!-- Base branch should be `dev`.

     What changed and why belongs in the linked issue, not here. This
     template is the evidence that the change is ready to merge, not a
     description of it.

     If it is not ready, convert it to a draft - "Convert to draft" in the
     Reviewers section of the Conversation tab. -->

Closes #

## AppConfig changes

<!-- Config changes, or "No application property changes". Name every service
     that picks the change up, and say whether config-server has to be
     restarted for it to take effect. -->

## Local build output

There is no Maven build here. The stack coming up clean is the gate:

    $ docker compose config --quiet && docker compose up -d
    $ docker compose ps

    NAME                          STATUS
    homecrew-postgres             Up (healthy)
    homecrew-kafka                Up (healthy)
    homecrew-service-discovery    Up (healthy)
    ...

<!-- Paste the real table. Every container must reach `healthy`, not just
     `running` - one that is up but not yet healthy refuses connections and
     everything waiting on it fails to start.

     If anything came up degraded and you decided to live with it, say so. -->

## Before review

- [ ] Self review: you read your own diff in the GitHub UI before requesting
      a review
- [ ] Verified by hand - there is no build gate in this repository, so the
      output above is the only evidence there is

<!-- Re-request review from anyone who left comments once you have addressed
     them - they are not notified otherwise. -->

## Impact

<!-- Tick only what applies. Nothing the hooks already enforce is listed
     here: formatting, Checkstyle, SpotBugs, coverage, secrets, branch name
     and commit format are all green or this branch could not have been
     pushed. -->

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

## Before merge

- [ ] Branch is up to date with `dev` and the full gate was re-run
      after the rebase or merge

<!-- Nothing deploys on merge. `deploy.yml` fires only on a
     `repository_dispatch` from a service repository, and it checks out this
     repository at that moment - so a compose change merged here takes effect
     on the *next* service deployment, not on this merge. If it needs to
     apply now, push a service or run the compose commands on the host. -->
