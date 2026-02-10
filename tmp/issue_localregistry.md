# Compat.toml not updated when registering pre-release versions with changed compat bounds

Hi LocalRegistry developers,

## Context

I maintain a private Julia registry using LocalRegistry.jl to manage packages in the [control-toolbox](https://github.com/control-toolbox) organization. We use **pre-release (beta) versions** extensively during development, e.g. `v0.8.10-beta`, `v0.8.11-beta`, `v0.8.11-beta.1`, etc.

I'm not sure pre-release versions are a fully supported use case for LocalRegistry — if they are not, feel free to close this issue. I'm reporting it in case it's useful, and I provide a minimal reproduction script below.

## Problem

When registering two successive pre-release versions that share the same `major.minor.patch` but differ only in the pre-release tag (e.g. `v0.1.0-beta.1` → `v0.1.0-beta.2`), **LocalRegistry does not update `Compat.toml`** even if the compat bounds have changed between the two versions. The new compat entries are silently ignored.

When the patch version is bumped instead (e.g. `v0.1.0-beta.1` → `v0.1.1-beta.1`), the compat update works correctly.

## Minimal reproduction

The script below demonstrates the issue with two test cases:

- **Case 1** — `v0.1.0-beta.1` → `v0.1.0-beta.2` (same patch, only pre-release tag changes): compat change for `DepA` is **silently ignored**, `Compat.toml` is not updated.
- **Case 2** — `v0.2.0-beta.1` → `v0.2.1-beta.1` (patch version bumped): compat change for `DepA` is **correctly applied**.

<details>
<summary>reproduce.jl (click to expand)</summary>

```julia
using Pkg, LocalRegistry, UUIDs

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
ROOT = mktempdir()
println("Working directory: $ROOT")

registry_bare = joinpath(ROOT, "TestRegistry_bare")
run(`git init --bare $registry_bare`)
create_registry("TestRegistry", registry_bare; description="Test registry", push=true)

registry_path = joinpath(first(DEPOT_PATH), "registries", "TestRegistry")

atexit() do
    rm(registry_path; force=true, recursive=true)
    rm(ROOT; force=true, recursive=true)
end

# ---------------------------------------------------------------------------
# Helper: create and register a simple dependency package
# ---------------------------------------------------------------------------
function create_dep(path, name, uuid; versions)
    mkdir(path)
    mkdir(joinpath(path, "src"))
    write(joinpath(path, "src", "$name.jl"), "module $name\nend\n")
    run(Cmd(`git init`, dir=path))
    for v in versions
        write(joinpath(path, "Project.toml"), """
        name = "$name"
        uuid = "$uuid"
        version = "$v"
        """)
        run(Cmd(`git add .`, dir=path))
        run(Cmd(`git commit -m "$name v$v"`, dir=path))
        run(Cmd(`git tag v$v`, dir=path))
        register(path; registry="TestRegistry",
                 repo="https://example.com/$name.jl.git", push=true)
        println("  ✓ Registered $name v$v")
    end
end

# ---------------------------------------------------------------------------
# Helper: register a version of MainPkg with given compat
# ---------------------------------------------------------------------------
function register_main(mainpkg_path, main_uuid, version, dep_uuid, dep_compat)
    write(joinpath(mainpkg_path, "Project.toml"), """
    name = "MainPkg"
    uuid = "$main_uuid"
    version = "$version"

    [deps]
    Dep = "$dep_uuid"

    [compat]
    Dep = "$dep_compat"
    julia = "1.10"
    """)
    run(Cmd(`git add .`, dir=mainpkg_path))
    run(Cmd(`git commit --allow-empty -m "MainPkg v$version"`, dir=mainpkg_path))
    run(Cmd(`git tag v$version`, dir=mainpkg_path))
    register(mainpkg_path; registry="TestRegistry",
             repo="https://example.com/MainPkg.jl.git", push=true)
    println("  ✓ Registered MainPkg v$version")
end

# ---------------------------------------------------------------------------
# Create a dependency package with two versions
# ---------------------------------------------------------------------------
dep_uuid = string(uuid4())
println("\n--- Registering Dep ---")
create_dep(joinpath(ROOT, "Dep"), "Dep", dep_uuid; versions=["0.1.0", "0.2.0"])

# ---------------------------------------------------------------------------
# Create MainPkg
# ---------------------------------------------------------------------------
mainpkg_path = joinpath(ROOT, "MainPkg")
mkdir(mainpkg_path)
mkdir(joinpath(mainpkg_path, "src"))
write(joinpath(mainpkg_path, "src", "MainPkg.jl"), "module MainPkg\nusing Dep\nend\n")
run(Cmd(`git init`, dir=mainpkg_path))
main_uuid = string(uuid4())

compat_file = joinpath(registry_path, "M", "MainPkg", "Compat.toml")

# =========================================================================
# CASE 1: beta.1 → beta.2 (same patch, only pre-release tag changes)
#         Expected: Compat.toml should reflect the new compat for Dep
# =========================================================================
println("\n" * "#"^60)
println("# CASE 1: v0.1.0-beta.1 → v0.1.0-beta.2 (same patch)")
println("#"^60)

println("\n  Registering v0.1.0-beta.1 with Dep = \"0.1\"")
register_main(mainpkg_path, main_uuid, "0.1.0-beta.1", dep_uuid, "0.1")
println("\n  Compat.toml after v0.1.0-beta.1:")
println(read(compat_file, String))

println("  Registering v0.1.0-beta.2 with Dep = \"0.1, 0.2\"")
register_main(mainpkg_path, main_uuid, "0.1.0-beta.2", dep_uuid, "0.1, 0.2")
println("\n  Compat.toml after v0.1.0-beta.2:")
compat1 = read(compat_file, String)
println(compat1)

if occursin("Dep = \"0.1-0.2\"", compat1) || occursin("Dep = \"0.1, 0.2\"", compat1)
    println("  ✓ OK: Dep compat was updated")
else
    println("  ✗ BUG: Dep compat was NOT updated — still shows the old value")
end

# =========================================================================
# CASE 2: beta.1 → next patch beta.1 (patch version bumped)
#         Expected: Compat.toml should reflect the new compat for Dep
# =========================================================================
println("\n" * "#"^60)
println("# CASE 2: v0.2.0-beta.1 → v0.2.1-beta.1 (patch bump)")
println("#"^60)

println("\n  Registering v0.2.0-beta.1 with Dep = \"0.1\"")
register_main(mainpkg_path, main_uuid, "0.2.0-beta.1", dep_uuid, "0.1")
println("\n  Compat.toml after v0.2.0-beta.1:")
println(read(compat_file, String))

println("  Registering v0.2.1-beta.1 with Dep = \"0.1, 0.2\"")
register_main(mainpkg_path, main_uuid, "0.2.1-beta.1", dep_uuid, "0.1, 0.2")
println("\n  Compat.toml after v0.2.1-beta.1:")
compat2 = read(compat_file, String)
println(compat2)

if occursin("Dep = \"0.1-0.2\"", compat2)
    println("  ✓ OK: Dep compat was updated")
else
    println("  ✗ BUG: Dep compat was NOT updated")
end

# =========================================================================
# Summary
# =========================================================================
println("\n" * "="^60)
println("LocalRegistry version: ",
        Pkg.dependencies()[Base.UUID("89398ba2-070a-4b16-a995-9893c55d93cf")].version)
println("="^60)

Pkg.Registry.rm("TestRegistry")
println("\nDone.")
```

</details>

## Output

### Case 1: `v0.1.0-beta.1` → `v0.1.0-beta.2` (same patch) — **compat not updated**

After registering `v0.1.0-beta.1` with `Dep = "0.1"`:

```toml
[0]
Dep = "0.1"
julia = "1.10.0-1"
```

After registering `v0.1.0-beta.2` with `Dep = "0.1, 0.2"`:

```toml
[0]
Dep = "0.1"
julia = "1.10.0-1"
```

**`Compat.toml` was not updated.** The new compat bound for `Dep` was silently ignored.

### Case 2: `v0.2.0-beta.1` → `v0.2.1-beta.1` (patch bump) — **OK**

After registering `v0.2.1-beta.1` with `Dep = "0.1, 0.2"`:

```toml
[0]
julia = "1.10.0-1"

["0-0.2.0"]
Dep = "0.1"

["0.2.1-0"]
Dep = "0.1-0.2"
```

The compat change is correctly reflected.

## Root cause hypothesis

It seems that the compat compression treats pre-release versions sharing the same `major.minor.patch` as belonging to the same version range. When only the pre-release tag changes (`beta.1` → `beta.2`), the new version falls into the existing range and the compat difference is not detected.

## Environment

- LocalRegistry v0.5.7
- Julia 1.12.1
- macOS (aarch64)
