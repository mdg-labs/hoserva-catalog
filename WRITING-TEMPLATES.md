# Writing a template

A template is what lets someone go from *"I want Jellyfin"* to *Jellyfin is
running* in one form. This guide walks through writing one for the Hoserva
catalog, from a blank folder to a pull request, and then lists every field and
rule in one place.

How to contribute in general — the sign-off, the branch to target, the commit
style — is in [CONTRIBUTING.md](CONTRIBUTING.md).

## What a template is

A template is one folder, `templates/<id>/`, holding two files:

```
templates/sonarr/
├── compose.yaml   a normal Docker Compose file, plus an x-hoserva block
└── icon.svg       the app's icon
```

`compose.yaml` is a valid Compose file you could run by hand with
`docker compose up`. Compose ignores keys that start with `x-`, so the
`x-hoserva` block at the end is invisible to Docker; Hoserva reads it to build
the install form, show the app in the catalog and notice later updates.

When someone installs the template, Hoserva asks for the template's
**inputs**, writes their answers to a `.env` file next to the Compose file, and
starts the stack. Every `${NAME}` in the Compose file is one of those inputs.

## A walkthrough

The Sonarr template is a good model; it is short and uses the common patterns.

### 1. Gather the upstream documentation

Every template is written from the application's own documentation and image
documentation, and never copied or adapted from another catalog's template.
Before you write anything, find:

- the page describing how to run the app in a container: its image, the ports
  it listens on, the folders it stores data in, and the environment variables
  it reads;
- the image to use: the application's official image, or the linuxserver.io
  image where one exists;
- a version tag to pin, from the image's registry or release page.

### 2. Create the folder

Pick the id: lowercase letters, digits and single hyphens, usually the app's
name (`nginx-proxy-manager`, `uptime-kuma`). Create `templates/<id>/`.

### 3. Write the Compose part

Start with the provenance comments, then the services:

```yaml
# Written from https://docs.linuxserver.io/images/docker-sonarr/ and https://wiki.servarr.com/docker-guide (D19).
# Icon: https://github.com/Sonarr/Sonarr/blob/develop/Logo/Sonarr.svg, GPL-3.0 (the license of that repository), none
#
# One mount at /data holds the downloads and the library, so hardlinks and
# instant moves work. In Sonarr set the root folder to /data/media/tv.
services:
  sonarr:
    image: lscr.io/linuxserver/sonarr:4.0.20.3014-ls326
    environment:
      PUID: "99"
      PGID: "100"
      TZ: ${TZ}
    volumes:
      - ${APPDATA}/sonarr:/config
      - ${DATA}:/data
    ports:
      - ${WEBUI_PORT}:8989
    restart: unless-stopped
```

- The first line names every page you wrote the template from.
- The second line says where the icon came from, under which license, and
  whether you changed it (see [Icons](#icons)).
- Anything a user needs to know after installing — like which folder to pick
  inside the app — goes in a short comment below.
- Everything the user chooses is a `${NAME}`; everything else is spelled out.

### 4. Write the `x-hoserva` block

```yaml
x-hoserva:
  schema: 1
  id: sonarr
  revision: 1
  title: Sonarr
  categories: [media, automation]
  icon: icon.svg
  docs: https://docs.linuxserver.io/images/docker-sonarr/
  webui: http://{host}:${WEBUI_PORT}
  inputs:
    APPDATA:    { kind: path, role: appdata, default: /mnt/cache/appdata }
    DATA:
      kind: path
      role: share
      default: /mnt/user/data
      label: Data folder
      description: The folder that holds both downloads (torrents) and the media library (media).
    WEBUI_PORT: { kind: port, default: 8989, label: Web UI port }
    TZ:         { kind: timezone }
```

Declare one input for every `${NAME}` in the Compose part. Give an input a
`label` and a `description` whenever its name alone would not tell someone
new to self-hosting what to enter. The [reference](#the-x-hoserva-block) below
lists every field.

### 5. Add the icon

Put the icon next to `compose.yaml` under the name `x-hoserva.icon` gives,
following [Icons](#icons).

### 6. Check it locally

Run what CI runs, from the repository root:

```sh
.ci/check-layout.sh
.ci/validate.sh templates
```

`validate.sh` runs `hoserva template lint` from the Hoserva version pinned in
`.ci/hoserva-version` (through `go run`, so it needs Go), then
`docker compose config` on each template and a registry query for each image
(so it needs Docker and network access). A lint failure names the line and
what is wrong with it.

### 7. Open a pull request

Open it against `dev`. The pull request template has a short checklist of the
points below.

## The `x-hoserva` block

| Field | Required | What it holds |
|---|---|---|
| `schema` | yes | Always `1`. |
| `id` | yes | The template id; must equal the folder name. Lowercase letters, digits, single hyphens. |
| `revision` | yes | Starts at `1` and increases with every change to the template. Installed apps compare it to offer an update. |
| `title` | yes | The app's name as shown in the catalog. |
| `categories` | yes | One or more lowercase categories, for example `[media, automation]`. Reuse the ones existing templates use where they fit. |
| `icon` | yes | File name of the icon next to `compose.yaml`. |
| `docs` | yes | The main upstream documentation page the template was written from (`http://` or `https://`). |
| `webui` | no | Address of the app's web interface. `{host}` stands for the server's address, `${NAME}` for an input: `http://{host}:${WEBUI_PORT}/web`. |
| `inputs` | no | The values the install form asks for, described below. |

### Inputs

Each key under `inputs` is a variable name — uppercase letters, digits and
underscores, starting with a letter — and each value describes it:

| Field | What it holds |
|---|---|
| `kind` | What the value is; see the table below. Required. |
| `role` | Required for `path` and `device` inputs, not allowed on any other kind. |
| `default` | The preset value. |
| `label` | A plain-language name shown in the form. |
| `description` | Help text shown under the field. |

| Kind | Use it for | Rules |
|---|---|---|
| `path` | A folder on the server mounted into the container. | Needs a `role`. A default is an absolute path. |
| `port` | A port on the server mapped to the container. | A default is a number from 1 to 65535. |
| `string` | Any other value the user types, such as a claim token. | |
| `secret` | A password or key the app needs. | No default: Hoserva generates a random value at install and writes it only to the stack's `.env`. |
| `timezone` | The server's time zone, usually as `TZ`. | Left empty, it becomes `UTC`. |
| `device` | A GPU for hardware transcoding or acceleration. | Role `gpu`. Not referenced anywhere: if the user picks a GPU, Hoserva maps its render device into every service and adds the render group. Leaving it empty installs without one. |

Path roles decide where the folder lives and what the folder picker offers:

| Role | For | Default must be |
|---|---|---|
| `appdata` | The app's own configuration and database. | Required, under `/mnt/cache` — normally `/mnt/cache/appdata`, used as `${APPDATA}/<id>`. |
| `share` | A user folder the app reads and writes, such as a data or photo library. | If given, under `/mnt/user`. |
| `media` | A media library a media server reads. | If given, under `/mnt/user`. |
| `downloads` | A download folder. | If given, under `/mnt/user`. |

Every input must be used: referenced as `${NAME}` in the Compose part or in
`webui`, or passed in through `env_file: .env` on a service, which hands the
container every input. A `device` input is the exception.

## What the Compose part may contain

Before installing, Hoserva shows the user a summary of what the app gets
access to on the server — privileged mode, host networking, added
capabilities, devices, folders outside the pool and cache, and so on. That
summary is computed from the Compose content, never declared by the template,
so a template cannot understate what it asks for. To keep it complete, lint
accepts only the Compose keys the summary understands:

- Top level: `services`, `volumes`, `networks`, `name`, and `x-` extensions.
- Services: the everyday keys (`image`, `environment`, `volumes`, `ports`,
  `restart`, `depends_on`, `healthcheck`, `command`, `user`, limits and the
  like) and the privilege-relevant ones the summary reports (`privileged`,
  `network_mode`, `cap_add`, `devices`, `security_opt`, `group_add` and
  others).
- Refused: `build` (ship a pinned image instead), `include` and `extends` from
  another file (spell the services out), `secrets` and `configs` (use a
  `secret` input), and `volumes_from` a container that is not one of the
  template's own services.

A bind mount's host side is a `path` input or an absolute path written out in
full — never a relative path like `./config`, and never a `port` or `string`
input.

Ask for no more than the app needs. Every added privilege shows up in the
summary the user sees before installing; use one only when the upstream
documentation says the app needs it, and say why in a comment.

## Conventions

### Sources

- Write the template from the app's upstream documentation and image
  documentation, never from another catalog's template.
- Name every page you used in the `# Written from <URL> (D19).` first line, and
  the main one in `x-hoserva.docs`.

### Images

- Use the application's official image, or the linuxserver.io image where one
  exists.
- Pin a version tag rather than `latest` wherever upstream publishes versions.

### Defaults

- Appdata on the cache: `/mnt/cache/appdata`, mounted as `${APPDATA}/<id>`.
- Shared data and media on the pool, under `/mnt/user`.
- `PUID: "99"` and `PGID: "100"` where the image supports them; lint refuses
  any other value.
- No privileges, host networking, capabilities or devices the app does not
  need.
- A web UI port input named `WEBUI_PORT` with the app's usual port as default
  (name each port after its use when an app has several, like `ADMIN_PORT`),
  and a `TZ` timezone input where the image reads one.

### Media data layout

The apps that fetch, import or read the media library share one layout, so
downloads and the library sit on one filesystem and hardlinks and atomic moves
work (the Sonarr and Radarr image documentation explains why separate `/tv`,
`/movies` and `/downloads` mounts lose them):

- Sonarr, Radarr, Bazarr, qBittorrent and later download clients and library
  managers take one `DATA` input (`kind: path`, `role: share`, default
  `/mnt/user/data`) and mount it at `/data`. Downloads go under
  `/data/torrents`, the library under `/data/media` with `tv`, `movies` and
  `music` below it.
- Media servers such as Jellyfin and Plex take a `MEDIA` input (`kind: path`,
  `role: media`, default `/mnt/user/data/media`) and mount it at `/data/media`,
  so a default install lines up with the apps above.
- Apps that need neither take an `APPDATA` input only.

### Icons

Every template has an icon next to `compose.yaml`, named by `x-hoserva.icon`,
used only to identify the application.

- Use the application's own logo from its upstream repository or website where
  that source's stated license permits redistribution, and the SVG over a PNG.
  Copy the file unchanged unless the license asks for more.
- Otherwise use the application's file from
  [selfhst/icons](https://github.com/selfhst/icons), which is licensed
  CC-BY-4.0 (the repository's `LICENSE`). The logos stay the trademarks of
  their projects.
- Never use an image whose license is not stated, and never one from the
  linuxserver.io API (`project_logo`). If no source is usable, leave the
  template for a later change.
- Keep the file under about 32 KB.
- Record where it came from in a comment in `compose.yaml`, which ships in the
  archive so the attribution travels with the icon:
  `# Icon: <source URL>, <license>, <changes or none>`.

## Updating a template

- Increase `x-hoserva.revision` by one in the same change — a new image tag, a
  changed default, a fixed path all count.
- When upstream changed something, add the page that documents it to the
  `# Written from` line.
- Run the same local checks as for a new template.

## Where the format is defined

The `x-hoserva` format and the checker that enforces it live in the
[Hoserva repository](https://github.com/mdg-labs/hoserva) (`internal/template/`),
and CI runs the version pinned in `.ci/hoserva-version`. This guide describes
that version, and so does its JSON Schema:
[`internal/template/schema/v1.json`](https://github.com/mdg-labs/hoserva/blob/629408e5e79d16397a34731dea940040796f720b/internal/template/schema/v1.json).
An editor that understands JSON Schema can use it to check the `x-hoserva`
block as you type. When the pin moves, this link moves with it. If lint and this
guide ever disagree, lint is right — and please open an issue so the guide gets
fixed.
