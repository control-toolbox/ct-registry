#
# Reproduction script for overlapping compat ranges bug in LocalRegistry.jl
# with pre-release (beta) versions.
#
# Summary:
#   When registering successive pre-release versions that only differ by the
#   pre-release tag (e.g. v0.1.0-beta.1 → v0.1.0-beta.2), LocalRegistry does
#   not correctly update Compat.toml when compat bounds change. The dependency
#   remains in the catch-all [0] section AND gets added to a version-specific
#   section, producing overlapping ranges.
#
#   However, when bumping the patch/minor version (e.g. v0.1.0-beta.1 →
#   v0.1.1-beta.1), the update works correctly.
#
# This causes Pkg to error:
#   "Overlapping ranges for <Dep> for version <v> in registry."
#
# Real-world case: CTFlows in a private registry (control-toolbox/ct-registry)
#   - CTFlows v0.8.10-beta: CTBase = "0.16-0.17", CTModels = "0.6"
#   - CTFlows v0.8.11-beta: CTModels changes → correctly split out of [0],
#     but CTBase stays in [0]
#   - CTFlows v0.8.11-beta.1: CTBase changes → added to ["0.8.11-0"] but NOT
#     removed from [0] → overlapping ranges
#

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
# Helper: check if a key appears under [0] in a Compat.toml string
# ---------------------------------------------------------------------------
function has_key_in_section_0(content, key)
    in_section_0 = false
    for line in split(content, "\n")
        if line == "[0]"
            in_section_0 = true
        elseif startswith(line, "[")
            in_section_0 = false
        elseif in_section_0 && startswith(line, key)
            return true
        end
    end
    return false
end

# ---------------------------------------------------------------------------
# Helper: register a version of MainPkg with given compat
# ---------------------------------------------------------------------------
function register_main(mainpkg_path, main_uuid, version, depa_uuid, depb_uuid,
                       depa_compat, depb_compat)
    write(joinpath(mainpkg_path, "Project.toml"), """
    name = "MainPkg"
    uuid = "$main_uuid"
    version = "$version"

    [deps]
    DepA = "$depa_uuid"
    DepB = "$depb_uuid"

    [compat]
    DepA = "$depa_compat"
    DepB = "$depb_compat"
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
# Create dependency packages
# ---------------------------------------------------------------------------
depa_uuid = string(uuid4())
depb_uuid = string(uuid4())

println("\n--- Registering DepA ---")
create_dep(joinpath(ROOT, "DepA"), "DepA", depa_uuid; versions=["0.1.0", "0.2.0"])

println("\n--- Registering DepB ---")
create_dep(joinpath(ROOT, "DepB"), "DepB", depb_uuid; versions=["0.1.0", "0.2.0"])

# =========================================================================
# CASE 1: beta.1 → beta.2 (same patch version, only pre-release tag changes)
#         Expected: BUG — compat not updated correctly
# =========================================================================
println("\n" * "#"^60)
println("# CASE 1: v0.1.0-beta.1 → v0.1.0-beta.2 (same patch)")
println("#"^60)

mainpkg1_path = joinpath(ROOT, "MainPkg1")
mkdir(mainpkg1_path)
mkdir(joinpath(mainpkg1_path, "src"))
write(joinpath(mainpkg1_path, "src", "MainPkg.jl"), "module MainPkg\nusing DepA, DepB\nend\n")
run(Cmd(`git init`, dir=mainpkg1_path))
main1_uuid = string(uuid4())

# v0.1.0-beta.1: DepA = "0.1", DepB = "0.1"
println("\n  Registering v0.1.0-beta.1 (DepA = \"0.1\", DepB = \"0.1\")")
register_main(mainpkg1_path, main1_uuid, "0.1.0-beta.1",
              depa_uuid, depb_uuid, "0.1", "0.1")

compat_file1 = joinpath(registry_path, "M", "MainPkg", "Compat.toml")
println("\n  Compat.toml after v0.1.0-beta.1:")
println(read(compat_file1, String))

# v0.1.0-beta.2: broaden DepA = "0.1, 0.2" (DepB unchanged)
println("  Registering v0.1.0-beta.2 (DepA = \"0.1, 0.2\", DepB = \"0.1\")")
register_main(mainpkg1_path, main1_uuid, "0.1.0-beta.2",
              depa_uuid, depb_uuid, "0.1, 0.2", "0.1")

println("\n  Compat.toml after v0.1.0-beta.2:")
compat1 = read(compat_file1, String)
println(compat1)

if has_key_in_section_0(compat1, "DepA")
    println("  ✗ BUG: DepA still in [0] → overlapping ranges for v0.1.0-beta.2")
else
    println("  ✓ OK: DepA correctly removed from [0]")
end

# =========================================================================
# CASE 2: beta.1 → next patch beta.1 (patch version bumped)
#         Expected: OK — compat updated correctly
# =========================================================================
println("\n" * "#"^60)
println("# CASE 2: v0.2.0-beta.1 → v0.2.1-beta.1 (patch bump)")
println("#"^60)

# We reuse the same MainPkg registry entry, continuing from Case 1.

# v0.2.0-beta.1: DepA = "0.1", DepB = "0.1"
println("\n  Registering v0.2.0-beta.1 (DepA = \"0.1\", DepB = \"0.1\")")
register_main(mainpkg1_path, main1_uuid, "0.2.0-beta.1",
              depa_uuid, depb_uuid, "0.1", "0.1")

println("\n  Compat.toml after v0.2.0-beta.1:")
println(read(compat_file1, String))

# v0.2.1-beta.1: broaden DepA = "0.1, 0.2" (DepB unchanged)
println("  Registering v0.2.1-beta.1 (DepA = \"0.1, 0.2\", DepB = \"0.1\")")
register_main(mainpkg1_path, main1_uuid, "0.2.1-beta.1",
              depa_uuid, depb_uuid, "0.1, 0.2", "0.1")

println("\n  Compat.toml after v0.2.1-beta.1:")
compat2 = read(compat_file1, String)
println(compat2)

if has_key_in_section_0(compat2, "DepA")
    println("  ✗ BUG: DepA still in [0] → overlapping ranges for v0.2.1-beta.1")
else
    println("  ✓ OK: DepA correctly removed from [0]")
end

# =========================================================================
# Summary
# =========================================================================
println("\n" * "="^60)
println("LocalRegistry version: ",
        Pkg.dependencies()[Base.UUID("89398ba2-070a-4b16-a995-9893c55d93cf")].version)
println("="^60)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
Pkg.Registry.rm("TestRegistry")
println("\nDone. Temporary files were in: $ROOT")
