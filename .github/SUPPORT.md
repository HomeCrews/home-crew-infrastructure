# Support

HomeCrew is a personal project maintained by one person in their own time.
There is no SLA and no support rota. Questions are welcome; answers arrive
when they arrive.

Read this page before opening an issue - most setup problems are answered here
or in one of the four documents it points at.

## Where to ask

The fifteen repositories each own a different kind of problem. Asking in the
right one is the difference between a same-week answer and a silent issue.

| Your problem | Where it belongs |
|---|---|
| A build fails on formatting, Checkstyle, SpotBugs or coverage | `_standards/README.md`, then an issue on the repo that failed |
| A git hook rejects your branch name or commit message | `.github/CONTRIBUTING.md` in this repo |
| `docker compose up` fails, a port clashes, a container will not start | home-crew-infrastructure |
| A deployment did not happen or deployed the wrong image | home-crew-infrastructure |
| A shared configuration value is wrong or missing | home-crew-config |
| A service returns the wrong thing, or crashes | this repository's bug form |
| You think you found a vulnerability | `.github/SECURITY.md` - do not open an issue |

If you genuinely cannot tell which repository owns it, open it here and it
will be moved.

## Before you open an issue

Three things account for most of the round trips:

- **The commit you are on.** `git rev-parse --short HEAD`. "Latest" is not a
  commit; the default branch moves.
- **Where you ran it.** Locally with `./mvnw spring-boot:run`, under docker
  compose, or against the Hetzner dev deployment. The three fail differently.
- **The full command and its full output.** Not the last line. The first
  `[ERROR]` is usually the real one and the last is usually a consequence.

The bug form asks for all three and will not submit without them. That is
deliberate.

Redact tokens, passwords and connection strings before pasting. Issues are
public and are indexed.

## First-run problems

Two things catch almost everyone, both documented in `_standards/README.md`:

- **The wrong JDK.** These projects target Java 25. An older JDK fails every
  module at compile with `release version 25 not supported`, which reads like
  the project is broken rather than the toolchain. `./verify.sh` checks this
  before it runs anything.
- **gitleaks is not installed.** The pre-commit hook fails loudly rather than
  skipping the scan, because an unverified scan is not a pass.
  `brew install gitleaks`.

## Related documents

- `.github/CONTRIBUTING.md` - branch names, commit format, the local gate
- `.github/SECURITY.md` - reporting a vulnerability privately
- `.github/CODE_OF_CONDUCT.md` - how we treat each other
- `_standards/README.md` - what the quality gates are and how to change them
