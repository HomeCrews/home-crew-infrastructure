# Contributing to home-crew-infrastructure

One of fifteen repositories that make up HomeCrew. The rules below are
identical in all fifteen, and in the twelve Java services they are enforced by
blocking git hooks rather than discovered in CI.

## Before you start

Nothing to install. There is no build and no hook set in this repository.

If you are also working in the twelve service repositories, install gitleaks
anyway - their pre-commit hook requires it and fails loudly without it.

    brew install gitleaks

## Branching

`dev` is the integration branch. `main` is the release branch. Everything else
is a feature branch off `dev`, named to a fixed shape:

```
dev                                    exempt
main                                   exempt
dev__YYYYmmDD__lower_snake_name        everything else
```

Lowercase only, single underscores inside the name, double underscores between
sections. The year must be last year, this year or next year - a cheap typo
catch.

```
dev__20260916__add_spotless_config     ok
feature/spotless                       rejected
dev__20260916__Add-Config              rejected
dev__19990916__old                     rejected (implausible year)
```

The `dev__` prefix is literal and applies even in the two repositories whose
default branch is `main`. There is no `main__` form. That reads oddly the
first time; it is the pattern, not a mistake.

## Commits

Conventional Commits, subject capped at 100 characters:

```
<type>[(scope)][!]: <description>
```

Types: `feat fix docs style refactor perf test build ci chore revert`. Merge,
revert, `fixup!` and `squash!` messages pass through untouched.

```
fix(docker): copy the jar by glob instead of a pinned filename
build: add formatting, lint and coverage gates with git hooks
ci: sync infrastructure config during deployment
```

Lowercase after the type, no trailing period, imperative mood. Say what the
commit does, not what you did.

## The local gate

There is none. This repository is in `apply.py`'s `HOOKS_OPT_OUT`, so
`core.hooksPath` is unset and no hook runs at commit or push time.

That means the branch-name check, the Conventional Commits check and the
gitleaks scan are all conventions here rather than gates. Follow them anyway -
the sections above still apply, and a reviewer will hold you to them. The
difference is that nothing will stop you first.

If you want the checks locally without installing the shared hooks, run
gitleaks by hand before you push:

    gitleaks git --staged --redact --no-banner

## Opening a pull request

Base the pull request on `dev`.

One logical change per pull request. A formatting sweep and a behaviour change
in the same diff means the reviewer reads neither carefully.

Fill in the template. The checklist is not ceremony - every line on it maps to
something that will otherwise be caught later and more expensively. Read your
own diff in the GitHub UI before you request a review; it is a different
reading experience from `git diff` and it catches different things.

## Where things live

Fifteen repositories means the right fix is often not in the repository where
you noticed the problem.

| Changing | Edit |
|---|---|
| A shared configuration value | `home-crew-config/application.yml` |
| Ports, images, compose topology, the deploy | `home-crew-infrastructure/docker-compose.yml` |
| A quality rule, a hook, checkstyle, spotbugs | `_standards/templates/`, then `./apply.py` |
| The CI secret-scan step | `_standards/add-ci-scan.py` |
| These community files | `_standards/templates/github/`, then `./add-github-meta.py` |
| Behaviour of this service | here |

Hardcoding a value here that belongs in home-crew-config works locally and
then diverges across twelve services. Adding a port here without mirroring it
into docker-compose works locally and then fails on deploy.

## Notes

- **Nothing checks this repository before a push.** No formatter, no secret
  scan, no branch-name check. The conventions above are conventions here, not
  gates. Read your own diff.

- **`.editorconfig` and `.gitattributes` are generated.** They come from
  `_standards/templates/` and the next `apply.py` run overwrites them. Change
  the template, not the copy.

- **These community files are generated too.** `README.md` is seeded once and
  then yours to edit. Everything else under `.github/` except `workflows/`
  comes from `_standards/templates/github/` and is overwritten on every
  `add-github-meta.py` run.

## Code of conduct

By participating you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).
