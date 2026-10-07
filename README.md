# Hoserva catalog

The curated template catalog of [Hoserva](https://github.com/mdg-labs/hoserva),
the home server platform for mixed-size disks. Each template is a directory
holding a Compose file with an `x-hoserva` block and, where a usable source
exists, an icon. On every merge CI builds all of them into one signed archive
and publishes it at `https://catalog.hoserva.dev`, from where Hoserva fetches
and verifies it.

The `x-hoserva` schema, its validator and the code that fetches and verifies the
archive live in the Hoserva repository (`internal/template/`,
`docs/internal/04-containers.md` §7). This repository holds template content and
the CI that publishes it.

## Layout

| Path | Holds |
|---|---|
| `templates/<id>/compose.yaml`, `templates/<id>/<icon>` | one template per directory, named by its id; the icon is present when a usable source exists |
| `signing-key.pub.pem` | the catalog's Ed25519 public key |
| `.ci/` | the build, signing and validation scripts, their tests and fixtures |
| `.github/workflows/catalog.yml` | the CI |
| `WRITING-TEMPLATES.md` | the guide to writing a template |

Templates live in `templates/` so the repository's first page stays short as the
catalog grows. CI validates and builds `templates/` only, and
`.ci/check-layout.sh` fails when a template directory sits anywhere else at the
repository root. Tooling and fixtures live under `.ci/` because
`hoserva template lint` treats every top-level directory of the folder it is
given that does not start with a dot as a template.

## Adding a template

[WRITING-TEMPLATES.md](WRITING-TEMPLATES.md) walks through it step by step.
In short:

1. Create `templates/<id>/`. The id is lowercase letters, digits and
   single hyphens, and the directory name equals `x-hoserva.id`.
2. Write `templates/<id>/compose.yaml` as a valid Compose file with an
   `x-hoserva` block. Put the icon `x-hoserva.icon` names next to it; when no
   usable source exists, leave out both and record the sources you searched in
   the `# Icon:` comment (see [Icons](WRITING-TEMPLATES.md#icons)).
3. Write the template from the application's upstream documentation, link that
   documentation in `x-hoserva.docs`, and pin an image tag rather than `latest`
   where upstream publishes versions.
4. Increase `x-hoserva.revision` with every later change to the template.
5. Open a pull request against `dev`. CI runs the checks below.

## What CI checks

On every pull request and push, the `Validate` job runs:

- `.ci/check-layout.sh`: no template directory outside `templates/`.
- `hoserva template lint templates` from the Hoserva version pinned in
  `.ci/hoserva-version` (a full commit SHA), through
  `go run github.com/mdg-labs/hoserva/cmd/hoserva@<pin>`. Bumping the pin is a
  normal commit. A catalog with an empty or missing `templates/` skips this step.
- `docker compose config` for each template, with every `${VAR}` set from the
  `x-hoserva.inputs` defaults (a placeholder where an input has none).
- That every image in each template exists, with a manifest query
  (`docker buildx imagetools inspect`). A manifest the registry reports missing
  fails at once; any other failure is retried, three attempts in total
  (`CATALOG_IMAGE_ATTEMPTS`), before it fails.

The `Tooling tests` job runs the tests of the scripts in `.ci/tests/`
(`.ci/tests/run.sh`) and `shellcheck` over them.

Branches follow the same model as the Hoserva repository: `dev` is the working
branch and `main` is release-only, moved by a pull request from `dev`.

| Event | What runs |
|---|---|
| Pull request | tooling tests and validation; no secret is available |
| Push to `dev` | those, then build and sign as a dry run; the result is the `catalog-dist` workflow artifact and nothing is deployed |
| Push to `main` | those, then the GitHub Release `serial-<serial>`, then the GitHub Pages deploy and a fetch-back check, then a request to rebuild hoserva.dev |
| `workflow_dispatch` | as a push to the branch it is run on; only `main` releases and deploys |

The build job runs only after validation and the tooling tests pass, the
release job only after the build job and the deploy job only after both, so a
template that fails validation never reaches a published archive. The last job,
the site rebuild request below, runs only after the deploy and its fetch-back.

## The archive

`catalog.tar.zst` is a zstd-compressed tar containing `index.json` and every
template directory (`<id>/compose.yaml` and its icon, where it has one), and
nothing else. The archive layout does not follow the repository layout: the contents of
`templates/` sit at the archive root, so an entry is `<id>/compose.yaml`, never
`templates/<id>/compose.yaml`. Entries are sorted by name, with owner `0:0`, mode `0644` for files (whatever
mode the checkout gave them) and `0755` for directories, and mtime equal to the
serial.

`index.json`:

```json
{
  "schema": 1,
  "serial": 1790830071,
  "generatedAt": "2026-10-01T04:47:51Z",
  "templates": [
    {
      "id": "jellyfin",
      "revision": 4,
      "title": "Jellyfin",
      "categories": ["media"],
      "icon": "icon.svg",
      "docs": "https://docs.linuxserver.io/images/docker-jellyfin/",
      "contentHash": "<hex SHA-256>"
    }
  ]
}
```

- `schema` is the version of this file's format.
- `templates` is sorted by `id`; the other fields are read from each template's
  `x-hoserva` block. A catalog without templates has `"templates": []`.
- `contentHash` is the hex SHA-256 over every file in the template directory, in
  byte-wise sorted order of their paths relative to that directory. For each
  file the hash input is the path, a NUL byte, the file's length in decimal, a
  NUL byte and the file's contents.
- `generatedAt` is the serial as an RFC 3339 UTC time.

### Signature

`catalog.tar.zst.sig` is the raw 64-byte Ed25519 signature over the bytes of
`catalog.tar.zst`, made with `openssl pkeyutl -sign -rawin`. It verifies with Go's
`ed25519.Verify` and with:

```sh
openssl pkeyutl -verify -pubin -inkey signing-key.pub.pem -rawin \
  -in catalog.tar.zst -sigfile catalog.tar.zst.sig
```

The private key is held only as the `HOSERVA_CATALOG_SIGNING_KEY` secret of this
repository, is separate from Hoserva's release-signing key, and is never
committed. Before signing, the build checks that the secret's public half equals
`signing-key.pub.pem` and fails on a mismatch or an unreadable key.

### Serial

The serial is the build's Unix time in seconds, so every build increases it:
a rebuild with no template change still produces a higher serial, and an
unchanged build is not skipped. Before deploying, CI fetches the archive
currently published at `catalog.hoserva.dev`, verifies its signature, and fails
unless the new serial is strictly higher. Nothing published yet (HTTP 404)
passes; a failed fetch fails the deploy. After the deploy, CI fetches the archive
and its signature again, verifies the signature against `signing-key.pub.pem` and
checks that the served serial equals the one just built.

### Releases: the immutable location of every serial

`catalog.hoserva.dev` always serves the latest archive only. Every archive
published from `main` is also kept as a GitHub Release of this repository, so a
build that pins one archive by serial and SHA-256 can still fetch it after later
publishes:

- Tag and release name: `serial-<serial>` (title `Catalog serial <serial>`),
  targeting the commit that was built.
- Assets, the exact bytes deployed to Pages:
  `https://github.com/mdg-labs/hoserva-catalog/releases/download/serial-<serial>/catalog.tar.zst`
  and `.../catalog.tar.zst.sig`.

The archive is trusted through its signature, never its host: verify it as
described under Signature.

The release job is the only job with `contents: write`. It runs only on `main`
(never on a pull request or `dev`), after the serial guard and a check that the
built commit is still the tip of `main`, and it fails, creating nothing, if the
tag `serial-<serial>` already exists or cannot be looked up: a release is never
overwritten or re-uploaded. Releases are meant to be immutable; turning on the
repository's immutable-releases setting is a maintainer action this repository
does not perform.

The release is created before the Pages deploy, so a Pages archive always has
its release. If the deploy then fails or is refused (the built commit is no
longer the tip of `main`), the release of a serial that Pages never served
remains. That is safe: it is a correctly signed archive, no installation
refreshes from the releases, and the next publish has a higher serial.
Re-running only a failed deploy job finishes the publish while the built commit
is still the tip of `main`. Re-running the release job fails on its existing
tag; re-run the whole workflow instead, whose rebuild has a new serial.

### Only the newest commit publishes

Right before the release and again right before the Pages deploy, CI looks up
the tip of `main` on GitHub and fails unless it is the commit being built, and
fails if the lookup fails. A run for an older commit (queued behind a newer
one, or an old run re-run) therefore never publishes over a newer one, even
though its serial, taken at build time, would be higher. The release and deploy
jobs also share one `catalog-pages` concurrency group, so they run one at a
time.

### Asking hoserva.dev to rebuild

hoserva.dev lists the catalog at `/apps`. After a successful deploy and
fetch-back, the `notify` job sends one `repository_dispatch` event of type
`catalog-published` to `mdg-labs/hoserva`, with the new serial in
`client_payload`, so the site picks up the archive within minutes instead of at
its daily rebuild (`.ci/notify-published.sh`).

- It uses the repository secret `GH_TOKEN`, a personal access token. The
  minimum it needs is permission to send `repository_dispatch` to
  `mdg-labs/hoserva`: for a classic token the `repo` scope, for a fine-grained
  one `Contents: write` on that repository alone. Nothing else in this
  repository's CI uses it.
- Only that one step of the `notify` job sees the token. It never runs for a pull
  request or a push to `dev`, and the token is never printed.
- This request never fails a publish. A missing `GH_TOKEN` or a failed call is
  a `::warning::` in the job log and the job succeeds; the catalog is already
  served, and the site's daily rebuild catches up.

## Running the tooling tests

```sh
.ci/tests/run.sh
```

They need `bash`, `curl`, `jq`, `openssl`, `python3` with PyYAML, GNU `tar` and
`zstd`. They stub `docker`, `go` and `gh` and never touch a registry or GitHub; keys are
generated per test run in a temporary directory and deleted afterwards.

## License

MIT, see [LICENSE](LICENSE).
