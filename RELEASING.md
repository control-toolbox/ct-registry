# `ct-registry` and package releases

This document describes how the control-toolbox organization uses the private
[`ct-registry`](https://github.com/control-toolbox/ct-registry) Julia registry and how
beta and stable releases are published.

## Why use `ct-registry`?

`ct-registry` is used for beta releases and pre-release integration testing. It allows a
package to be tested together with beta versions of other control-toolbox packages before
those changes are published as stable releases in the Julia General registry.

For example, a change in `CTBase` can be released as a beta, then tested in `CTModels`,
`CTSolvers`, `CTDirect`, `CTFlows`, `CTLie`, `CTParser`, or `OptimalControl` before the
corresponding stable releases are made.

A beta release is not intended to replace the stable version for regular users. It is a
way for the organization to develop and test coordinated changes across repositories.

## Versioning convention

Package versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html), as
Pkg reads it: the breaking component is the leftmost non-zero one, so in `0.Y.Z` a
breaking change bumps `Y`. The organization uses the `-beta` pre-release suffix and does
not use release-candidate (`-rc`) versions. The rules are `REL1`–`REL6` of
[ct-conventions](https://github.com/control-toolbox/ct-conventions/blob/main/rules/release.md);
an agent releases a package with the
[release recipe](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release.md)
of ct-agents.

Every release, whether beta or stable, must use a new version number. A beta version is
never changed into a stable release with the same version number. For example:

```text
1.2.0       existing stable release
1.2.1-beta  first beta release
1.2.2-beta  next beta release
1.2.3       next stable release
```

Update the `version` field in `Project.toml` before each release. The version in
`Project.toml`, the registry entry, and the GitHub tag must agree.

## Publishing a beta release

Beta releases are registered in `ct-registry` with `LocalRegistry`.

### 1. Update and commit the version

In the package repository, update `Project.toml`, for example:

```toml
version = "1.2.1-beta"
```

Commit the change and push the commit to the branch that will be released.

### 2. Register the beta in `ct-registry`

Install `LocalRegistry` if necessary:

```julia
using Pkg
Pkg.add("LocalRegistry")
```

From the package environment, register the package in `ct-registry`:

```julia
using LocalRegistry
using MyPackage

register(
    MyPackage;
    registry = "ct-registry",
    repo = "git@github.com:control-toolbox/MyPackage.jl.git",
)
```

The local registry must be available in the Julia depot. If it has not been added yet:

```julia
using Pkg
pkg> registry add git@github.com:control-toolbox/ct-registry.git
```

The registry is private, so SSH access to GitHub is required.

### 3. Create the GitHub release

After registering the beta, create a GitHub release for the same version. The tag must
include the `v` prefix and match the package version:

```text
v1.2.1-beta
```

The release can be created either from the command line or through the GitHub web
interface. Creating only the registry entry is not sufficient: every beta release must
also have its corresponding Git tag and GitHub release.

### 4. Test the beta in dependent packages

The beta can now be selected by projects that have access to `ct-registry`. Use it to
test the coordinated changes in the other control-toolbox repositories before publishing
stable versions.

## Publishing a stable release

Stable releases are registered in the Julia General registry through JuliaRegistrator.

**Before registering, the package must resolve from General alone** (`REL4`): no
`[compat]` bound may be satisfied by betas only. The CI of the packages uses
`ct-registry`, so it does not see it; the `Registrable` check of the release PR does (see
[`registrable.yml`](https://github.com/control-toolbox/CTActions/blob/main/docs/workflows/registrable.md)
in CTActions).

**The mention of the bot starts a registration wherever it appears** in an issue: in a
comment, in the description, in a code block (`REL6`). So write it **once**, in one
comment, when everything else is done; never in the description of the issue, never in a
pull request. If the registration fails, decide what to do before posting it again.

The comment, with the release notes:

```text
@JuliaRegistrator register

Release notes:

<the CHANGELOG entry of the version>

<the "What's Changed" of the GitHub release>
```

A common workflow for preparing the release notes is:

1. Create the GitHub release (tag `vX.Y.Z` on the merge commit of the release PR).
2. Ask GitHub to generate the release notes, from the **previous stable** release
   (`REL5`): `gh release create vX.Y.Z --generate-notes --notes-start-tag vPREVIOUS`, or
   choose the previous tag in the web interface.
3. Open the release issue, with no mention of the bot in its description.
4. Post the comment above, once.

If two stable releases do not have consecutive version numbers (`REL3`), which happens
when betas took the numbers in between (`0.4.2`, `0.4.3-beta`, then `0.4.4`), add the
following to a comment on the Julia registry pull request to confirm that the version
jump is intentional:

```text
[merge approved]
```

## Using `ct-registry` in CTActions workflows

The reusable workflows in
[`CTActions`](https://github.com/control-toolbox/CTActions) accept the
`use_ct_registry` input. Set it to `true` when the workflow needs packages from the
private registry:

```yaml
jobs:
  test:
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

The `SSH_KEY` secret gives the workflow access to the private registry. The same input is
available in the CTActions workflows that need to resolve private beta dependencies,
including CI, coverage, documentation, and breakage testing.

Set `use_ct_registry: false` or omit it when the workflow only uses packages from the
General registry.
