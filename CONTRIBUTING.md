## Contributing to the Hoserva catalog

This repository holds the curated templates of
[Hoserva](https://github.com/mdg-labs/hoserva) and the CI that publishes them.
Template requests and template pull requests are tracked here. The
`x-hoserva` schema, its validator and the fetch-and-verify code are tracked in
the Hoserva repository.

### Contribution terms: Developer Certificate of Origin, no CLA

Every commit must carry a `Signed-off-by:` trailer certifying the
[Developer Certificate of Origin](https://developercertificate.org/):

```
Signed-off-by: Jane Doe <jane@example.com>
```

`git commit -s` adds it. A pull request carrying a commit without one is not
accepted: the `dco` check (`.github/workflows/dco.yml`) runs on every pull
request and every push to `dev`, and fails on a commit with no `Signed-off-by:`
trailer matching its author's email. To fix a failing pull request, add the
trailer to each commit it names, for example `git rebase --signoff dev`, and
push again. There is no Contributor License Agreement.

### The branch flow

- Base your branch on `dev` and open the pull request against `dev`.
- `main` is release-only. It moves only when the maintainer promotes `dev`
  through a pull request, and the catalog at `catalog.hoserva.dev` is rebuilt
  and published only from `main`.
- Use Conventional Commits, for example `feat(jellyfin): add the template`, and
  keep one logical change per commit.

### Writing a template

[WRITING-TEMPLATES.md](WRITING-TEMPLATES.md) walks through writing a template
and lists every field, rule and convention: upstream documentation as the only
source, pinned images, defaults, the media data layout and icons. Before
opening a pull request, run the checks CI runs: `.ci/check-layout.sh` and
`.ci/validate.sh templates` (needs Go and Docker, and queries the registries
for each image).

### Image updates

`.github/workflows/image-updates.yml` runs daily and on demand
(`.ci/image-updates.py`). It compares the image each template on `dev` pins with
what its registry publishes and keeps **one open issue per template**, labelled
`image-update`. The issue names the pinned and the new tag per service, links the
registry page and the image documentation, and restates the steps of
[Updating a template](WRITING-TEMPLATES.md#updating-a-template). The workflow
only reports: the update itself is a change you make from the upstream
documentation, with `Fixes #<n>` in the commit message.

- A newer version than the open issue names supersedes it: the workflow opens the
  new issue first, then comments `Superseded by #<n>.` on the old one and closes
  it as not planned.
- An open issue whose version change is no longer reported (a rule changed, or
  upstream withdrew the tag, while `dev` still pins a version older than the
  issue's) is commented on (`No newer version is reported any more for this
  template; closing.`) and closed as not planned, and the job summary lists the
  close. A rebuild left over does not keep it open or open a new one. An issue
  whose version `dev` already pins, or pins a newer one than, is left alone, even
  when a rebuild of that pin is reported, and closes with the commit that reaches
  `main`.
- A rebuild-only bump (a new `-ls<N>` suffix on the same version, or a new digest
  behind a pinned tag) never opens an issue. When an issue is already open, it is
  edited in place to name the newest rebuild: same number, no comment, nothing
  closed.
- A newer major version is listed on its own line in the issue, as it can need
  migration steps. A change only in that line also edits the open issue in place;
  only a newer version within the same major supersedes it. A template whose id
  ends in `-<major>` (one template per major, such as `postgresql-18`) never gets
  a major line: the next major is a new template.
- An issue that already matches what `dev` pins is left alone, and closes with the
  commit that reaches `main`.
- A template whose registry lookup fails is skipped, its issue untouched, and the
  run fails once every other template is done. The job summary lists each one.
- A registry that answers HTTP 429 or 503 is waited for (its `Retry-After`, or a
  short doubling backoff), at most four retries per request and within a bounded
  wait per image and per run. Past that, or past the run's time budget, the image
  is a listed failure like any other. A tag list is walked in full, up to a page
  cap: ghcr.io lists tags in no useful order, so a long list (immich's
  machine-learning image holds 210 pages) cannot be narrowed.
- Only issues carrying the `image-update` label and the workflow's hidden marker
  are ever edited or closed; `template-fix`, `template-request` and anything filed
  by hand are not.

#### The versioning ruleset

What counts as a newer version differs between images, so it is one declarative
ruleset, `.ci/image-updates-rules.yaml`, and the only place an image-specific
exception lives. The first rule whose `match` (a `host/repository` glob, such as
`docker.io/kopia/kopia`) covers an image applies; `defaults` covers the rest.
Each rule names a scheme, each implemented once:

- `semver` (the default): tags of the pinned tag's shape, every run of digits
  read as a number, whose first number has as many digits as the pinned tag's. The
  newest with the same first number is the update; a larger first number is a
  major.
- `calver`: the same shape rule for date-like versions (`2026.9.4`). The first
  number is a year, so the newest tag of any year is the update and there is no
  major.
- `linuxserver`: the version tag the registry's `latest` points at, found by
  digest, looked for among the 20 newest version tags of the registry's listing
  (lscr.io and ghcr.io list in push order; a `latest` further back is a listed
  failure, never "no update"). `-ls<N>` is only compared between builds of one
  version; a different version is compared by its numbers, or counts as changed
  when it is not numeric (a commit hash).

`include` and `exclude` hold regular expressions applied to tags before any
comparison (`exclude` adds to the defaults', which already drop `-rc`, `-beta`,
`-alpha`, `-dev`, `-nightly` and `-unstable` tags). A filter the pinned tag itself
matches is not applied, so a pin on a prerelease line follows that line.

A rule with `majors: false` never reports a newer major for its images, while
updates within the pinned major still open an issue. The ruleset sets it for the
database servers (PostgreSQL, MariaDB, MySQL, MongoDB), which are kept per major:
a newer major there is a migration, not an update.

A rule with `versions: false` never reports a newer version or major for its
images. It is for companion images whose tag the upstream release of a sibling
service fixes: immich's compose file pins the database image
(`ghcr.io/immich-app/postgres`: PostgreSQL, VectorChord and pgvecto.rs versions)
and the valkey image, so a newer tag of either is not an update immich supports.
A changed digest behind the pinned tag is still listed as a rebuild when an issue
is open for the template anyway, and a rebuild alone opens none. A rule covers the
image in every template that pins it.

An image the check cannot classify under its rule, such as a pinned tag without a
number, outside the registry's tag list or outside the rule's `include`, is a
listed failure, never "no update". To teach the check a new image's versioning,
add a rule to the `rules` list, for example a `calver` rule or an `exclude` for its
nightly tags, and a fixture image to `.ci/fixtures/image-updates/` that
`.ci/tests/test-image-updates.sh` covers. A rule matches only its own images, so
existing ones keep their outcome.

### Changing the CI

The scripts, tests and fixtures are under `.ci/`; run `.ci/tests/run.sh` after a
change. Pin every third-party GitHub Action by commit SHA, with the version in a
comment. Never commit a private key, not even a test one: tests generate theirs.

### License

The catalog is licensed under the MIT License (see `LICENSE`). By contributing,
you agree your contribution is licensed under the same terms. Each packaged
application keeps its own upstream license.
