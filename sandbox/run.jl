#!/usr/bin/env julia

"""
Exercise the command-line interface against a stub terminal emulator and throwaway
configurations.

Nothing here touches the network, a real host, a real credential, or your desktop session,
so the sandbox is a safe way to confirm that the tool still behaves after a change. Run it
directly:

```bash
julia sandbox/run.jl
```

The driver is called in process through `SshAutoLogin.main`; one scenario spawns
`scripts/run.jl` in a separate Julia process to verify the script wrapper as well. The
test suite includes this file and asserts the same expectations.
"""

if abspath(PROGRAM_FILE) == @__FILE__
    using Pkg
    Pkg.activate(dirname(@__DIR__); io=devnull)
    Pkg.instantiate(; io=devnull)
end
using SshAutoLogin

const REPOSITORY_ROOT = dirname(@__DIR__)
const DRIVER = joinpath(REPOSITORY_ROOT, "scripts", "run.jl")

# Distinctive so that the sandbox can assert it never appears in any output.
const SANDBOX_PASSWORD = "sandbox-password-never-printed"

# Stands in for ssh and sshpass; the wrapper scripts execute it and it exits at once.
const STUB_EXECUTABLE = "#!/bin/sh\nexit 0\n"

# Stands in for Konsole. It waits briefly, then executes each wrapper exactly as Konsole
# would, so that the self-deleting wrappers and the settle logic are genuinely exercised.
const STUB_KONSOLE = raw"""
#!/bin/sh
sleep 0.2
if [ "$1" = "--nofork" ] && [ "$2" = "--tabs-from-file" ]; then
    sed -n 's/.*;; command: //p' "$3" | while read -r wrapper; do
        "$wrapper" </dev/null >/dev/null 2>&1
    done
elif [ "$1" = "--separate" ]; then
    "$5" </dev/null >/dev/null 2>&1
fi
exit 0
"""

sandbox_config(mode::AbstractString) = """
[globals]
connect_timeout = 5
strict_host_key_checking = "accept-new"
log_level = "ERROR"

[terminal]
emulator = "konsole"
mode = "$(mode)"
hold = false
launch_settle_timeout = 10

[[targets]]
host = "192.0.2.10"
port = 22
user = "researcher"
password = "$(SANDBOX_PASSWORD)"
title = "Sandbox node 01"

[[targets]]
host = "192.0.2.11"
port = 2222
user = "researcher"
password = "$(SANDBOX_PASSWORD)"
title = "Sandbox node 02"
"""

# A misspelled key must be refused before anything is launched.
const MALFORMED_CONFIG = """
[globals]
connect_timeoutt = 5

[[targets]]
host = "192.0.2.10"
port = 22
user = "researcher"
password = "$(SANDBOX_PASSWORD)"
"""

"""
    with_sandbox(f)

Call `f(configs)` with stub `ssh`, `sshpass`, and `konsole` first on `PATH`, a private
`XDG_RUNTIME_DIR`, and a dictionary of throwaway configuration paths. Everything is
removed afterwards.
"""
function with_sandbox(f)
    return mktempdir() do dir
        bin = joinpath(dir, "bin")
        runtime = joinpath(dir, "runtime")
        mkpath(bin)
        mkpath(runtime)
        for name in ("ssh", "sshpass")
            path = joinpath(bin, name)
            write(path, STUB_EXECUTABLE)
            chmod(path, 0o700)
        end
        konsole = joinpath(bin, "konsole")
        write(konsole, STUB_KONSOLE)
        chmod(konsole, 0o700)

        configs = Dict{String, String}()
        for (key, text) in ("tabs" => sandbox_config("tabs"),
                            "windows" => sandbox_config("windows"),
                            "malformed" => MALFORMED_CONFIG)
            path = joinpath(dir, "config_$(key).toml")
            write(path, text)
            configs[key] = path
        end
        configs["missing"] = joinpath(dir, "does_not_exist.toml")

        return withenv("PATH" => bin * ":" * get(ENV, "PATH", ""),
                       "XDG_RUNTIME_DIR" => runtime) do
            return f(configs)
        end
    end
end

"""
    invoke_driver(arguments; spawn = false)

Run the driver with `arguments`, capturing both streams. The call is made in process
through `SshAutoLogin.main`; with `spawn = true` a separate Julia process runs
`scripts/run.jl` instead, which verifies the script wrapper itself.
Returns `(; exitcode, output)`.
"""
function invoke_driver(arguments::Vector{String}; spawn::Bool=false)
    buffer = IOBuffer()
    exitcode = if spawn
        command = `$(Base.julia_cmd()) --startup-file=no $(DRIVER) $(arguments)`
        run(pipeline(ignorestatus(command); stdout=buffer, stderr=buffer)).exitcode
    else
        SshAutoLogin.main(arguments; io=buffer, err=buffer)
    end
    return (; exitcode, output=String(take!(buffer)))
end

"""
    scenarios(configs)

Build the scenario list: arguments, expected exit status, fragments the output must
contain, whether to spawn `scripts/run.jl` instead of calling `main` in process, and
what each scenario demonstrates.
"""
function scenarios(configs::AbstractDict)
    return [(; arguments=["--config", configs["tabs"], "--dry-run"], expected=0,
             fragments=["konsole --nofork --tabs-from-file", "<runtime-dir>/tabs.konsole"],
             spawn=false, description="a dry run prints the emulator command"),
            (; arguments=["--config", configs["tabs"]], expected=0,
             fragments=["Sessions dispatched", "emulator_processes = 1"], spawn=false,
             description="tabs mode launches one window"),
            (; arguments=["--config", configs["windows"]], expected=0,
             fragments=["Sessions dispatched", "emulator_processes = 2"], spawn=false,
             description="windows mode launches one per target"),
            (; arguments=["--config", configs["malformed"]], expected=1,
             fragments=["connect_timeoutt"], spawn=false,
             description="a misspelled key is refused"),
            (; arguments=["--config", configs["missing"]], expected=1,
             fragments=["configuration file not found"], spawn=false,
             description="a missing file is reported"),
            (; arguments=["--bogus"], expected=1,
             fragments=["unrecognized option '--bogus'"], spawn=false,
             description="an unknown option is rejected"),
            (; arguments=["--config", configs["tabs"]], expected=0,
             fragments=["Sessions dispatched", "emulator_processes = 1"], spawn=true,
             description="scripts/run.jl forwards the arguments and the exit status")]
end

"""
    run_sandbox(; io = stdout, verbose = true)

Run every scenario and return a vector of
`(; description, expected, exitcode, leaked, missing_fragments)`. `leaked` reports
whether the sandbox password appeared in the output, which must never happen;
`missing_fragments` lists the expected output fragments that did not appear.
"""
function run_sandbox(; io::IO=stdout, verbose::Bool=true)
    return with_sandbox() do configs
        results = NamedTuple[]
        for scenario in scenarios(configs)
            outcome = invoke_driver(scenario.arguments; spawn=scenario.spawn)
            leaked = occursin(SANDBOX_PASSWORD, outcome.output)
            missing_fragments = [fragment
                                 for fragment in scenario.fragments
                                 if !occursin(fragment, outcome.output)]
            push!(results,
                  (; scenario.description, scenario.expected, exitcode=outcome.exitcode,
                   leaked, missing_fragments))
            if verbose
                ok = outcome.exitcode == scenario.expected && !leaked &&
                     isempty(missing_fragments)
                println(io, rpad(ok ? "[ok]" : "[UNEXPECTED]", 14), "exit ",
                        outcome.exitcode, " (expected ", scenario.expected, ")   ",
                        scenario.description)
                for fragment in missing_fragments
                    println(io, " "^14, "missing from the output: ", fragment)
                end
            end
        end
        return results
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("Running the command-line sandbox: stub emulator, throwaway configuration, no network.\n")
    results = run_sandbox()
    failures = count(r -> r.exitcode != r.expected || r.leaked ||
                          !isempty(r.missing_fragments), results)
    println("\n", length(results) - failures, " of ", length(results),
            " scenarios behaved as expected.")
    any(r -> r.leaked, results) && println("A credential leaked into the output.")
    exit(failures == 0 ? 0 : 1)
end
