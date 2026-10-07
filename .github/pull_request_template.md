<!-- Thanks for contributing! Open this pull request against `dev`. -->

## What this changes

<!-- The template(s) added or changed, and why. Link the issue: "Fixes #123". -->

## Checklist

- [ ] Written from the app's upstream documentation, listed in the `# Written from <URL> (D19).` comment, not copied from another catalog's template
- [ ] `x-hoserva.description` starts with a short app description (one or two sentences, at most 300 characters) written in my own words from the upstream documentation (see WRITING-TEMPLATES.md, step 5)
- [ ] Image pinned to a version tag rather than `latest` where upstream publishes versions
- [ ] Icon next to `compose.yaml`, with an `# Icon: <source URL>, <license>, <changes or none>` comment; or, when no usable source exists, no icon and no `x-hoserva.icon`, with the `# Icon:` comment recording the sources searched (see WRITING-TEMPLATES.md, Icons)
- [ ] `x-hoserva.revision` increased (for a change to an existing template)
- [ ] `.ci/check-layout.sh`, `hoserva template lint templates` and `.ci/validate.sh templates` pass locally
- [ ] Every commit carries a `Signed-off-by:` trailer (`git commit -s`)
