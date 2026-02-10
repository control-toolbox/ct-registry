#
# Reproduction script for overlapping compat ranges bug in LocalRegistry.jl
#
# Summary:
#   When registering successive versions of a package where different dependencies
#   change at different times, LocalRegistry can produce overlapping compat ranges
#   in Compat.toml, causing Pkg to error:
#     "Overlapping ranges for <Dep> for version <v> in registry."
#
# Scenario (mirrors a real-world case with CTFlows in a private registry):
#   - MainPkg v0.1.0: depends on DepA = "0.1" and DepB = "0.1"
#   - MainPkg v0.2.0: changes only DepB = "0.1, 0.2" (DepA unchanged)
#     → LocalRegistry moves DepB out of [0] into version-specific sections,
#       but DepA stays in [0] since it didn't change.
#   - MainPkg v0.3.0: now changes DepA = "0.1, 0.2" (and DepB = "0.1, 0.2")
#     → LocalRegistry adds DepA to ["0.3-0"] but does NOT remove it from [0].
#     → DepA now appears in BOTH [0] and ["0.3-0"], causing overlapping ranges.
#
# Expected Compat.toml (non-overlapping):
#   [0]
#   julia = "1.10.0-1"
#   ["0-0.1"]
#   DepA = "0.1"
#   DepB = "0.1"
#   ["0.2"]
#   DepA = "0.1"
#   DepB = "0.1-0.2"
#   ["0.3-0"]
#   DepA = "0.1-0.2"
#   DepB = "0.1-0.2"
#
# Actual (buggy) Compat.toml:
#   [0]
#   DepA = "0.1"          ← still here from v0.1.0!
#   julia = "1.10.0-1"
#   ["0-0.1"]
#   DepB = "0.1"
#   ["0.2"]
#   DepB = "0.1-0.2"
#   ["0.3-0"]
#   DepA = "0.1-0.2"      ← overlaps with [0] for version 0.3.0!
#   DepB = "0.1-0.2"
#

using Pkg, LocalRegistry, UUIDs

# ---------------------------------------------------------------------------
# Setup: create a temporary workspace
# ---------------------------------------------------------------------------
ROOT = mktempdir()
println("Working directory: $ROOT")

depa_path    = joinpath(ROOT, "DepA")
depb_path    = joinpath(ROOT, "DepB")
mainpkg_path = joinpath(ROOT, "MainPkg")

# ---------------------------------------------------------------------------
# Step 1: Create the local registry (bare git repo)
# ---------------------------------------------------------------------------
registry_bare = joinpath(ROOT, "TestRegistry_bare")
run(`git init --bare $registry_bare`)
create_registry("TestRegistry", registry_bare; description="Test registry", push=true)

# create_registry already clones the registry into ~/.julia/registries/TestRegistry
registry_path = joinpath(first(DEPOT_PATH), "registries", "TestRegistry")

# Ensure cleanup even on error
atexit() do
    rm(registry_path; force=true, recursive=true)
    rm(ROOT; force=true, recursive=true)
end

# ---------------------------------------------------------------------------
# Helper: create and register a simple package with given versions
# ---------------------------------------------------------------------------
function create_pkg(path, name, uuid; versions)
    mkdir(path)
    mkdir(joinpath(path, "src"))
    write(joinpath(path, "src", "$name.jl"), "module $name\nend\n")
    run(Cmd(`git init`, dir=path))
    for (i, v) in enumerate(versions)
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
# Step 2: Create dependency packages DepA (v0.1, v0.2) and DepB (v0.1, v0.2)
# ---------------------------------------------------------------------------
depa_uuid = string(uuid4())
depb_uuid = string(uuid4())

println("\n--- Registering DepA ---")
create_pkg(depa_path, "DepA", depa_uuid; versions=["0.1.0", "0.2.0"])

println("\n--- Registering DepB ---")
create_pkg(depb_path, "DepB", depb_uuid; versions=["0.1.0", "0.2.0"])

# ---------------------------------------------------------------------------
# Step 3: Register MainPkg v0.1.0 — depends on DepA = "0.1" AND DepB = "0.1"
# ---------------------------------------------------------------------------
main_uuid = string(uuid4())

println("\n--- Registering MainPkg ---")
mkdir(mainpkg_path)
mkdir(joinpath(mainpkg_path, "src"))
write(joinpath(mainpkg_path, "src", "MainPkg.jl"), "module MainPkg\nusing DepA, DepB\nend\n")
run(Cmd(`git init`, dir=mainpkg_path))

write(joinpath(mainpkg_path, "Project.toml"), """
name = "MainPkg"
uuid = "$main_uuid"
version = "0.1.0"

[deps]
DepA = "$depa_uuid"
DepB = "$depb_uuid"

[compat]
DepA = "0.1"
DepB = "0.1"
julia = "1.10"
""")
run(Cmd(`git add .`, dir=mainpkg_path))
run(Cmd(`git commit -m "MainPkg v0.1.0"`, dir=mainpkg_path))
run(Cmd(`git tag v0.1.0`, dir=mainpkg_path))
register(mainpkg_path; registry="TestRegistry",
         repo="https://example.com/MainPkg.jl.git", push=true)
println("  ✓ Registered MainPkg v0.1.0")

compat_file = joinpath(registry_path, "M", "MainPkg", "Compat.toml")
println("\n--- Compat.toml after v0.1.0 ---")
println(read(compat_file, String))

# ---------------------------------------------------------------------------
# Step 4: Register MainPkg v0.2.0 — change ONLY DepB = "0.1, 0.2" (DepA unchanged)
#         This causes LocalRegistry to split DepB out of [0], but DepA stays in [0].
# ---------------------------------------------------------------------------
write(joinpath(mainpkg_path, "Project.toml"), """
name = "MainPkg"
uuid = "$main_uuid"
version = "0.2.0"

[deps]
DepA = "$depa_uuid"
DepB = "$depb_uuid"

[compat]
DepA = "0.1"
DepB = "0.1, 0.2"
julia = "1.10"
""")
run(Cmd(`git add .`, dir=mainpkg_path))
run(Cmd(`git commit -m "MainPkg v0.2.0 — broaden DepB only"`, dir=mainpkg_path))
run(Cmd(`git tag v0.2.0`, dir=mainpkg_path))
register(mainpkg_path; registry="TestRegistry",
         repo="https://example.com/MainPkg.jl.git", push=true)
println("  ✓ Registered MainPkg v0.2.0")

println("\n--- Compat.toml after v0.2.0 ---")
println(read(compat_file, String))

# ---------------------------------------------------------------------------
# Step 5: Register MainPkg v0.3.0 — now broaden DepA = "0.1, 0.2" too
#         DepA should be moved out of [0] into version-specific sections.
#         BUG: LocalRegistry adds DepA to ["0.3-0"] but leaves it in [0].
# ---------------------------------------------------------------------------
write(joinpath(mainpkg_path, "Project.toml"), """
name = "MainPkg"
uuid = "$main_uuid"
version = "0.3.0"

[deps]
DepA = "$depa_uuid"
DepB = "$depb_uuid"

[compat]
DepA = "0.1, 0.2"
DepB = "0.1, 0.2"
julia = "1.10"
""")
run(Cmd(`git add .`, dir=mainpkg_path))
run(Cmd(`git commit -m "MainPkg v0.3.0 — broaden DepA compat"`, dir=mainpkg_path))
run(Cmd(`git tag v0.3.0`, dir=mainpkg_path))
register(mainpkg_path; registry="TestRegistry",
         repo="https://example.com/MainPkg.jl.git", push=true)
println("  ✓ Registered MainPkg v0.3.0")

# ---------------------------------------------------------------------------
# Step 6: Inspect Compat.toml for overlapping ranges
# ---------------------------------------------------------------------------
println("\n" * "="^60)
println("Contents of MainPkg/Compat.toml after v0.3.0:")
println("="^60)
compat_content = read(compat_file, String)
println(compat_content)
println("="^60)

# Parse: check if DepA appears under [0] section
let
    lines = split(compat_content, "\n")
    in_section_0 = false
    global bug_found = false
    for line in lines
        if line == "[0]"
            in_section_0 = true
        elseif startswith(line, "[")
            in_section_0 = false
        elseif in_section_0 && startswith(line, "DepA")
            global bug_found = true
        end
    end
end

if bug_found
    println("\n✗ BUG CONFIRMED: DepA appears in [0] AND in a version-specific")
    println("  section, causing overlapping ranges for version 0.3.0.")
    println("  Pkg will error with: \"Overlapping ranges for DepA for version 0.3.0 in registry.\"")
else
    println("\n✓ No overlap detected — DepA was correctly removed from [0].")
    println("  The bug may have been fixed in this version of LocalRegistry.")
end

println("\nLocalRegistry version: ", Pkg.dependencies()[Base.UUID("89398ba2-070a-4b16-a995-9893c55d93cf")].version)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
Pkg.Registry.rm("TestRegistry")
println("\nDone. Temporary files were in: $ROOT")
