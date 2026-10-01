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

Every template is written from the application's upstream documentation and
image, and never copied or adapted from another catalog's template. Link the
documentation you wrote it from in `x-hoserva.docs`.

- Prefer the application's official image, or the linuxserver.io image where one
  exists, with a pinned tag rather than `latest` where upstream publishes
  versions.
- Set sane defaults: appdata on the cache, media on the pool, no unnecessary
  privileges, `PUID=99` and `PGID=100` where the image supports them.
- Increase `x-hoserva.revision` with every change to a template.
- The id is the directory's name. Put the icon next to `compose.yaml`.

The steps are in [README.md](README.md#adding-a-template). Before opening a pull
request, run the checks CI runs: `hoserva template lint` from the version in
`.ci/hoserva-version`, and `.ci/validate.sh` (needs Docker, and queries the
registries for each image).

### Changing the CI

The scripts, tests and fixtures are under `.ci/`; run `.ci/tests/run.sh` after a
change. Pin every third-party GitHub Action by commit SHA, with the version in a
comment. Never commit a private key, not even a test one: tests generate theirs.

### License

The catalog is licensed under the MIT License (see `LICENSE`). By contributing,
you agree your contribution is licensed under the same terms. Each packaged
application keeps its own upstream license.
