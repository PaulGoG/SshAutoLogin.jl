# Run as a script, the suite activates the test environment itself. Under Pkg.test the
# sandboxed environment is already active and PROGRAM_FILE is empty, so nothing happens.
if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "activate.jl"))
end

using Test
using SshAutoLogin
using SshAutoLogin: is_valid_host, command_string, runtime_directory, purge_stale_launches!,
                    generate_target_wrapper_script, generate_tabs_file_content,
                    build_tabs_launch_command, build_single_window_command,
                    emulator_commands
using Aqua
using ExplicitImports

# JET follows the compiler, and each of its release series supports only a few Julia
# minors. It runs on the stable release alone: the LTS resolves an old series, and a
# pre-release may be ahead of JET.
const RUN_JET = VERSION >= v"1.12" && isempty(VERSION.prerelease)
if RUN_JET
    using JET
end

# Characters that must survive shell quoting unchanged.
const AWKWARD_PASSWORD = "p'ss#w\$ord`1 -x\\%é"

function write_executable(path::AbstractString, content::AbstractString)
    write(path, content)
    chmod(path, 0o700)
    return path
end

# Stub emulator that behaves like Konsole for the two supported invocations: it waits
# briefly (so that the settle logic is exercised) and then executes each wrapper script.
const CONSUMING_KONSOLE = """
#!/bin/sh
sleep 0.3
if [ "\$1" = "--separate" ] && [ "\$2" = "--tabs-from-file" ]; then
    sed -n 's/.*;; command: //p' "\$3" | while read -r command; do
        "\$command" </dev/null >/dev/null 2>&1
    done
elif [ "\$1" = "--separate" ] && [ "\$2" = "-p" ]; then
    "\$5" </dev/null >/dev/null 2>&1
fi
exit 0
"""

# Stub emulator that fails before opening anything.
const FAILING_KONSOLE = "#!/bin/sh\nexit 3\n"

# Stub emulator that outlives the settle timeout without executing anything.
const SLOW_KONSOLE = "#!/bin/sh\nsleep 1\nexit 0\n"

"""
    with_stub_environment(f, konsole_script)

Run `f(stub_dir, runtime_dir)` with stub `ssh`, `sshpass`, and `konsole` executables first
on `PATH` and a private `XDG_RUNTIME_DIR`.
"""
function with_stub_environment(f, konsole_script::AbstractString)
    mktempdir() do stub_dir
        mktempdir() do runtime_dir
            write_executable(joinpath(stub_dir, "ssh"), "#!/bin/sh\nexit 0\n")
            write_executable(joinpath(stub_dir, "sshpass"), "#!/bin/sh\nexit 0\n")
            write_executable(joinpath(stub_dir, "konsole"), konsole_script)
            withenv("PATH" => stub_dir * ":" * ENV["PATH"],
                    "XDG_RUNTIME_DIR" => runtime_dir) do
                return f(stub_dir, runtime_dir)
            end
        end
    end
end

function captured_error(f)
    try
        f()
    catch err
        return err
    end
    return nothing
end

const DRIVER = joinpath(dirname(@__DIR__), "scripts", "run.jl")

# Distinctive, so that the scenarios can assert it never appears in any output.
const SCENARIO_PASSWORD = "scenario-password-never-printed"

"""
    scenario_config(mode)

Configuration text with two targets, opened in terminal `mode` (`"tabs"` or `"windows"`).
"""
scenario_config(mode::AbstractString) = """
[globals]
connect_timeout = 5
strict_host_key_checking = "accept-new"
log_level = "ERROR"

[terminal]
mode = "$(mode)"
hold = false
launch_settle_timeout = 5

[[targets]]
host = "192.0.2.10"
port = 22
user = "researcher"
password = "$(SCENARIO_PASSWORD)"
title = "Scenario node 01"

[[targets]]
host = "192.0.2.11"
port = 2222
user = "researcher"
password = "$(SCENARIO_PASSWORD)"
title = "Scenario node 02"
"""

# A misspelled key must be refused before anything is launched.
const MALFORMED_CONFIG = """
[globals]
connect_timeoutt = 5

[[targets]]
host = "192.0.2.10"
port = 22
user = "researcher"
password = "$(SCENARIO_PASSWORD)"
"""

"""
    invoke_driver(arguments; spawn = false)

Run the driver with `arguments`, capturing both streams in one buffer. The call is made
in process through `SshAutoLogin.main`; with `spawn = true` a separate Julia process runs
`scripts/run.jl` instead, which verifies the script wrapper itself.
Returns `(; exitcode, output)`.
"""
function invoke_driver(arguments::Vector{String}; spawn::Bool=false)
    buffer = IOBuffer()
    exitcode = if spawn
        # Pkg.test exports a load path without the standard libraries; the driver
        # activates its own environment and must not inherit it.
        command = addenv(`$(Base.julia_cmd()) --startup-file=no $(DRIVER) $(arguments)`,
                         "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)
        # Both streams go to one pipe, read to end-of-file: on Julia 1.10 a buffer handed
        # to pipeline may still be filling when run returns.
        pipe = Pipe()
        process = run(pipeline(ignorestatus(command); stdout=pipe, stderr=pipe); wait=false)
        close(pipe.in)
        write(buffer, read(pipe))
        wait(process)
        process.exitcode
    else
        SshAutoLogin.main(arguments; io=buffer, err=buffer)
    end
    return (; exitcode, output=String(take!(buffer)))
end

@testset "SshAutoLogin.jl" begin
    @testset "Static analysis" begin
        Aqua.test_all(SshAutoLogin)
        RUN_JET && JET.test_package(SshAutoLogin; target_modules=[SshAutoLogin])
        @test ExplicitImports.check_no_implicit_imports(SshAutoLogin) === nothing
        @test ExplicitImports.check_no_stale_explicit_imports(SshAutoLogin) === nothing
    end

    @testset "Field validation" begin
        for host in ("node01.cluster.local", "192.168.1.10", "localhost", "a-b.c.", "::1",
                     "2001:db8::1", "::ffff:192.0.2.1")
            @test is_valid_host(host)
        end
        for host in ("", "host name", "bad_host!", "-leading.dash", "a..b", ":", "::",
                     "a"^254, "host;rm -rf /", "[2001:db8::1]", "[::1", "::1]",
                     "node01\n", "::1\n")
            @test !is_valid_host(host)
        end

        @test_throws ArgumentError SshTarget("", 22, "admin", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.1 0", 22, "admin", "secret")
        @test_throws ArgumentError SshTarget("host;rm -rf /", 22, "admin", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 0, "admin", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 70000, "admin", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin user", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "user@x", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "1abc", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin\n", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "a\nb")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "secret",
                                             "A ;; B")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "secret", "A; B")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "secret",
                                             "50% load")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "secret", "A\nB")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "secret", "title",
                                             "invalid_policy")

        err = captured_error(() -> SshTarget("192.168.1.10", 22, "admin", "top\tsecret"))
        @test err isa ArgumentError
        @test !occursin("secret", sprint(showerror, err))

        t = SshTarget("node01.cluster.local", 2222, "john.doe", AWKWARD_PASSWORD, "Node 01",
                      "yes")
        @test t.title == "Node 01"
        @test t.strict_host_key_checking == "yes"
        @test SshTarget("10.0.0.1", 2222, "root", "toor").title == "root@10.0.0.1:2222"
        @test SshTarget("2001:db8::1", 22, "root", "toor").host == "2001:db8::1"

        @test_throws ArgumentError GlobalConfig(0, "accept-new", "ERROR")
        @test_throws ArgumentError GlobalConfig(10, "invalid_policy", "ERROR")
        @test_throws ArgumentError GlobalConfig(10, "accept-new", "UNKNOWN")
        @test_throws ArgumentError GlobalConfig(10, "accept-new", "error")
        @test_throws ArgumentError TerminalOptions(:panes, false)
        @test_throws ArgumentError TerminalOptions(:tabs, false, 0)
        @test_throws ArgumentError TerminalOptions(:tabs, false, Inf)
        # A Real that is finite but beyond Float64, or positive but below it, is refused
        @test_throws ArgumentError TerminalOptions(:tabs, false, big(10)^309)
        @test_throws ArgumentError TerminalOptions(:tabs, false, big"1e-400")
        @test fieldnames(TerminalOptions) == (:mode, :hold, :launch_settle_timeout)
        @test TerminalOptions().launch_settle_timeout == 30.0
        @test TerminalOptions("windows", true, 5).mode == :windows
        @test_throws ArgumentError SessionConfig(GlobalConfig(), TerminalOptions(),
                                                 SshTarget[])
    end

    @testset "Credential redaction in show" begin
        t = SshTarget("192.168.1.10", 22, "admin", AWKWARD_PASSWORD, "Primary", "no")
        shown = sprint(show, t)
        @test occursin("<redacted>", shown)
        @test occursin("admin@192.168.1.10:22", shown)
        @test occursin("strict_host_key_checking = \"no\"", shown)
        @test !occursin(AWKWARD_PASSWORD, shown)
        config = SessionConfig(GlobalConfig(), TerminalOptions(), [t])
        @test !occursin(AWKWARD_PASSWORD, sprint(show, config))
        @test !occursin(AWKWARD_PASSWORD, sprint(show, MIME("text/plain"), [t]))
    end

    @testset "Configuration parsing" begin
        toml_content = """
        [globals]
        connect_timeout = 15
        strict_host_key_checking = "yes"
        log_level = "DEBUG"

        [terminal]
        mode = "windows"
        hold = true
        launch_settle_timeout = 2.5

        [[targets]]
        host = "node01.cluster.local"
        port = 2201
        user = "scientist"
        password = "alpha_password"
        title = "Node 1"

        [[targets]]
        host = "2001:db8::1"
        port = 2202
        user = "engineer"
        password = "beta_password"
        strict_host_key_checking = "accept-new"
        """
        mktemp() do path, io
            write(io, toml_content)
            close(io)
            config = load_config(path)
            @test config.globals.connect_timeout == 15
            @test config.globals.strict_host_key_checking == "yes"
            @test config.globals.log_level == "DEBUG"
            @test config.terminal.mode == :windows
            @test config.terminal.hold
            @test config.terminal.launch_settle_timeout == 2.5
            @test length(config.targets) == 2
            t1, t2 = config.targets
            @test t1.host == "node01.cluster.local"
            @test t1.port == 2201
            @test t1.user == "scientist"
            @test t1.password == "alpha_password"
            @test t1.title == "Node 1"
            @test t1.strict_host_key_checking === nothing
            @test t2.host == "2001:db8::1"
            @test t2.title == "engineer@2001:db8::1:2202"
            @test t2.strict_host_key_checking == "accept-new"
        end

        base_target = Dict{String, Any}("host" => "192.168.1.1", "port" => 22,
                                        "user" => "root", "password" => "x")
        @test parse_config(Dict{String, Any}("targets" => Any[base_target])) isa
              SessionConfig
        @test_throws ArgumentError parse_config(Dict{String, Any}("globals" =>
                                                                      Dict{String,
                                                                           Any}()))
        @test_throws ArgumentError parse_config(Dict{String, Any}("targets" => Any[]))
        @test_throws ArgumentError parse_config(Dict{String, Any}("targets" => Any[1]))

        without_password = delete!(copy(base_target), "password")
        err = captured_error(() -> parse_config(Dict{String,
                                                     Any}("targets" =>
                                                              Any[without_password])))
        @test err isa ArgumentError
        @test occursin("'password'", sprint(showerror, err))

        typo = merge(base_target, Dict{String, Any}("pasword" => "x"))
        err = captured_error(() -> parse_config(Dict{String, Any}("targets" => Any[typo])))
        @test err isa ArgumentError
        @test occursin("pasword", sprint(showerror, err))

        # The emulator key is gone: Konsole is the only emulator
        legacy_terminal = Dict{String, Any}("emulator" => "konsole")
        err = captured_error(() -> parse_config(Dict{String, Any}("terminal" =>
                                                                      legacy_terminal,
                                                                  "targets" =>
                                                                      Any[base_target])))
        @test err isa ArgumentError
        @test occursin("Unknown key(s) in [terminal]: emulator", sprint(showerror, err))

        wrong_type = merge(base_target, Dict{String, Any}("port" => "22"))
        err = captured_error(() -> parse_config(Dict{String,
                                                     Any}("targets" => Any[wrong_type])))
        @test err isa ArgumentError
        @test occursin("port", sprint(showerror, err))

        # Booleans are integers in Julia but never acceptable for numeric keys
        boolean_port = merge(base_target, Dict{String, Any}("port" => true))
        err = captured_error(() -> parse_config(Dict{String,
                                                     Any}("targets" => Any[boolean_port])))
        @test err isa ArgumentError
        @test occursin("'[[targets]] #1.port' must be of type Integer",
                       sprint(showerror, err))
        for (section, key) in (("globals", "connect_timeout"),
                               ("terminal", "launch_settle_timeout"))
            err = captured_error(() -> parse_config(Dict{String,
                                                         Any}(section => Dict{String,
                                                                              Any}(key => true),
                                                              "targets" =>
                                                                  Any[base_target])))
            @test err isa ArgumentError
            @test occursin("'[$(section)].$(key)'", sprint(showerror, err))
        end
        err = captured_error(() -> parse_config(Dict{String, Any}("globals" => 1,
                                                                  "targets" =>
                                                                      Any[base_target])))
        @test err isa ArgumentError
        @test occursin("'globals' must be of type", sprint(showerror, err))

        @test_throws ArgumentError parse_config(Dict{String,
                                                     Any}("terminal" => Dict{String,
                                                                             Any}("hold" => "yes"),
                                                          "targets" => Any[base_target]))
        @test_throws ArgumentError parse_config(Dict{String,
                                                     Any}("globals" => Dict{String,
                                                                            Any}("connect_timeout" =>
                                                                                     1.5),
                                                          "targets" => Any[base_target]))
        @test_throws ArgumentError parse_config(Dict{String, Any}("extra" => 1,
                                                                  "targets" =>
                                                                      Any[base_target]))

        mktemp() do path, io
            write(io, "[globals\n")
            close(io)
            @test_throws ArgumentError load_config(path)
        end

        # A syntax error is reported by kind and line number. The line itself is never
        # echoed: it may be the password line, or a password pasted without its key. No
        # parser error stays on the exception stack as a cause either, because the
        # display of an uncaught error prints causes, and that of a parser error prints
        # the line.
        head = "[[targets]]\nhost = \"192.168.1.1\"\n"
        for (text, line) in
            ((head * "port = 22\nuser = \"root\"\npassword = \"never-echoed\" x\n", 5),
             (head * "password = \"never-echoed\n", 3),
             (head * "never-echoed\nport = 22\n", 3),
             (head * "= 1\n", 3),
             ("[globals\n", 1))
            mktemp() do path, io
                write(io, text)
                close(io)
                err = captured_error(() -> load_config(path))
                @test err isa ArgumentError
                @test occursin("near line $(line).", sprint(showerror, err))
                @test !occursin("never-echoed", sprint(showerror, err))
                causes = try
                    load_config(path)
                    0
                catch
                    length(current_exceptions())
                end
                @test causes == 1
            end
        end

        # A file its owner cannot read is a configuration error, not a crash. Root reads
        # any file, so the case is skipped there.
        mktemp() do path, io
            close(io)
            chmod(path, 0o000)
            denied = try
                open(close, path)
                nothing
            catch err
                err isa SystemError || rethrow()
                err
            end
            if denied === nothing
                @test_skip "unreadable configuration file"
            else
                @test_throws ArgumentError load_config(path)
                err = IOBuffer()
                @test SshAutoLogin.main([path]; io=IOBuffer(), err=err) == 1
                message = String(take!(err))
                # The reason is the C library's text, in the locale of the process
                @test occursin("cannot be read: $(Libc.strerror(denied.errnum)).", message)
                @test !occursin("SystemError", message)
            end
        end
        # A path that cannot be inspected is a configuration error as well: a loop of
        # symbolic links, and a file in a directory that is not searchable (skipped for
        # root, which searches any directory).
        mktempdir() do dir
            loop = joinpath(dir, "loop.toml")
            symlink(loop, loop)
            locked = joinpath(dir, "locked")
            mkdir(locked)
            inside = joinpath(locked, "config.toml")
            write(inside, "")
            chmod(inside, 0o600)
            chmod(locked, 0o000)
            searchable = try
                isfile(joinpath(locked, "absent"))
                true
            catch err
                err isa Base.IOError || rethrow()
                false
            end
            searchable && @test_skip "configuration file in an unsearchable directory"
            cases = searchable ? [(loop, Libc.ELOOP)] :
                    [(loop, Libc.ELOOP), (inside, Libc.EACCES)]
            for (path, errno) in cases
                @test captured_error(() -> load_config(path)) isa ArgumentError
                causes = try
                    load_config(path)
                    0
                catch
                    length(current_exceptions())
                end
                @test causes == 1
                err = IOBuffer()
                @test SshAutoLogin.main([path]; io=IOBuffer(), err=err) == 1
                message = String(take!(err))
                @test occursin("cannot be read: $(Libc.strerror(errno)).", message)
                @test !occursin("IOError", message)
            end
            chmod(locked, 0o700)
        end
        @test_throws ArgumentError load_config(joinpath(tempdir(), "does-not-exist.toml"))

        # The template must satisfy the schema it documents.
        mktemp() do path, io
            write(io, read(joinpath(pkgdir(SshAutoLogin), "config.example.toml"), String))
            close(io)
            @test load_config(path) isa SessionConfig
        end

        # A configuration readable by others is refused before it is parsed.
        mktemp() do path, io
            write(io, toml_content)
            close(io)
            chmod(path, 0o644)
            err = captured_error(() -> load_config(path))
            @test err isa ArgumentError
            @test occursin("mode 644", sprint(showerror, err))
        end
    end

    @testset "Wrapper scripts and emulator commands" begin
        globals = GlobalConfig(10, "accept-new", "ERROR")
        target1 = SshTarget("192.168.1.10", 22, "admin", "plain1", "Primary Node")
        target2 = SshTarget("192.168.1.20", 2222, "guest", AWKWARD_PASSWORD,
                            "Secondary Node",
                            "no")

        script = generate_target_wrapper_script(target2, globals)
        @test startswith(script, "#!/usr/bin/env bash\n")
        @test !occursin("SSHPASS", script)

        # The wrapper delivers the ssh argument vector and the exact password over file
        # descriptor 3, then removes itself.
        mktempdir() do dir
            write_executable(joinpath(dir, "sshpass"),
                             "#!/bin/sh\nprintf '%s\\n' \"\$@\"\ncat <&3\n")
            wrapper = write_executable(joinpath(dir, "target.sh"), script)
            delivered = withenv("PATH" => dir * ":" * ENV["PATH"]) do
                return read(`$(wrapper)`, String)
            end
            expected = ["-d", "3", "ssh", "-p", "2222", "-o", "StrictHostKeyChecking=no",
                        "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR",
                        "-o", "PubkeyAuthentication=no",
                        "-o", "PreferredAuthentications=keyboard-interactive,password",
                        "-o", "NumberOfPasswordPrompts=1", "guest@192.168.1.20"]
            @test delivered == join(expected, "\n") * "\n" * AWKWARD_PASSWORD * "\n"
            @test !isfile(wrapper)
        end

        # With hold, the wrapper reports the exit status and waits for Enter.
        hold_script = generate_target_wrapper_script(target1, globals; hold=true)
        mktempdir() do dir
            write_executable(joinpath(dir, "sshpass"), "#!/bin/sh\nexit 7\n")
            wrapper = write_executable(joinpath(dir, "hold.sh"), hold_script)
            output = withenv("PATH" => dir * ":" * ENV["PATH"]) do
                return read(pipeline(`$(wrapper)`; stdin=IOBuffer("\n")), String)
            end
            @test occursin("exit status 7", output)
            @test !isfile(wrapper)
        end

        tabs = generate_tabs_file_content([target1, target2], ["/run/t1.sh", "/run/t2.sh"])
        @test tabs ==
              "title: Primary Node ;; command: /run/t1.sh\ntitle: Secondary Node ;; command: /run/t2.sh\n"
        @test_throws DimensionMismatch generate_tabs_file_content([target1], String[])

        config_tabs = SessionConfig(globals, TerminalOptions(:tabs, false),
                                    [target1, target2])
        @test build_tabs_launch_command("/run/tabs.konsole").exec ==
              ["konsole", "--separate", "--tabs-from-file", "/run/tabs.konsole"]
        window = build_single_window_command(target1, "/run/t1.sh")
        @test window.exec ==
              ["konsole", "--separate", "-p", "tabtitle=Primary Node", "-e", "/run/t1.sh"]
        @test window.env === nothing
        @test command_string(window) ==
              "konsole --separate -p 'tabtitle=Primary Node' -e /run/t1.sh"

        plan = plan_sessions(config_tabs)
        @test length(plan) == 1
        @test plan[1].exec[end] == "<runtime-dir>/tabs.konsole"
        config_windows = SessionConfig(globals, TerminalOptions(:windows, true),
                                       [target1, target2])
        plan_windows = plan_sessions(config_windows)
        @test length(plan_windows) == 2
        @test all(cmd -> cmd.env === nothing, plan_windows)
        @test all(cmd -> !occursin(AWKWARD_PASSWORD, command_string(cmd)), plan_windows)

        # Even a command that carries a secret in its environment is rendered safely.
        leaky = setenv(`echo x`, "SSHPASS" => AWKWARD_PASSWORD)
        @test command_string(leaky) == "echo x"
    end

    @testset "Runtime directory" begin
        mktempdir() do runtime_dir
            withenv("XDG_RUNTIME_DIR" => runtime_dir) do
                dir = runtime_directory()
                @test dir == joinpath(runtime_dir, "ssh-autologin")
                @test isdir(dir)
                @test (filemode(dir) & 0o777) == 0o700
                stale = mkpath(joinpath(dir, "launch-stale"))
                write(joinpath(stale, "target_1.sh"), "x")
                other = mkpath(joinpath(dir, "other"))
                purge_stale_launches!(dir, 3600)
                @test isdir(stale)
                purge_stale_launches!(dir, -1.0)
                @test !isdir(stale)
                @test isdir(other)
            end
        end
        withenv("XDG_RUNTIME_DIR" => nothing) do
            @test_throws ArgumentError runtime_directory()
        end
        withenv("XDG_RUNTIME_DIR" => joinpath(tempdir(), "does-not-exist")) do
            @test_throws ArgumentError runtime_directory()
        end
    end

    @testset "Launch with stub emulator" begin
        globals = GlobalConfig()
        targets = [SshTarget("10.0.0.1", 22, "admin", "p1", "Node A"),
                   SshTarget("10.0.0.2", 22, "admin", AWKWARD_PASSWORD, "Node B")]

        for terminal in (TerminalOptions(:tabs, false, 5),
                         TerminalOptions(:windows, true, 5))
            config = SessionConfig(globals, terminal, targets)
            with_stub_environment(CONSUMING_KONSOLE) do _, runtime_dir
                processes = launch_sessions(config)
                @test length(processes) == (terminal.mode == :tabs ? 1 : 2)
                foreach(wait, processes)
                @test all(p -> p.exitcode == 0, processes)
                @test isempty(readdir(joinpath(runtime_dir, "ssh-autologin")))
            end
        end

        # An emulator that exits without executing the wrappers: warning, directory removed.
        config = SessionConfig(globals, TerminalOptions(:tabs, false, 5), targets)
        with_stub_environment(FAILING_KONSOLE) do _, runtime_dir
            logs, processes = Test.collect_test_logs() do
                return launch_sessions(config)
            end
            warning = only(filter(log -> log.level == Base.CoreLogging.Warn, logs))
            @test occursin("exited before", warning.message)
            @test warning.kwargs[:emulator_exit_codes] == [3]
            @test warning.kwargs[:remaining] == ["target_1.sh", "target_2.sh"]
            wait(processes[1])
            @test processes[1].exitcode == 3
            @test isempty(readdir(joinpath(runtime_dir, "ssh-autologin")))
        end

        # An emulator still running when the settle timeout elapses: warning, files kept
        # with private modes, then purged by a later launch once they are stale.
        slow_config = SessionConfig(globals, TerminalOptions(:tabs, false, 0.2), targets)
        with_stub_environment(SLOW_KONSOLE) do stub_dir, runtime_dir
            processes = @test_logs (:warn, r"settle timeout") match_mode=:any launch_sessions(slow_config)
            session_dir = joinpath(runtime_dir, "ssh-autologin")
            launches = readdir(session_dir; join=true)
            @test length(launches) == 1
            launch_dir = launches[1]
            @test startswith(basename(launch_dir), "launch-")
            @test (filemode(launch_dir) & 0o777) == 0o700
            @test Set(readdir(launch_dir)) ==
                  Set(["target_1.sh", "target_2.sh", "tabs.konsole"])
            @test (filemode(joinpath(launch_dir, "target_1.sh")) & 0o777) == 0o700
            @test (filemode(joinpath(launch_dir, "tabs.konsole")) & 0o777) == 0o600
            foreach(wait, processes)
            sleep(0.5)
            # The kept directory is now older than one second; a launch with that settle
            # timeout and an emulator that executes the wrappers at once purges it and
            # removes its own directory.
            write_executable(joinpath(stub_dir, "konsole"),
                             replace(CONSUMING_KONSOLE, "sleep 0.3\n" => ""))
            later_config = SessionConfig(globals, TerminalOptions(:tabs, false, 1.0),
                                         targets)
            later = launch_sessions(later_config)
            foreach(wait, later)
            @test isempty(readdir(session_dir))
        end

        # A timeout beyond the range of a nanosecond counter is still a valid wait: the
        # launch waits for the stub, which consumes the wrappers after 0.3 s.
        @test SshAutoLogin.await_wrapper_consumption(String[], Base.Process[], 1.0e12)
        long_config = SessionConfig(globals, TerminalOptions(:tabs, false, 1.0e12), targets)
        with_stub_environment(CONSUMING_KONSOLE) do _, runtime_dir
            logs, processes = Test.collect_test_logs() do
                return launch_sessions(long_config)
            end
            foreach(wait, processes)
            @test !any(log -> log.level == Base.CoreLogging.Warn, logs)
            @test isempty(readdir(joinpath(runtime_dir, "ssh-autologin")))
        end

        mktempdir() do empty_dir
            withenv("PATH" => empty_dir) do
                @test_throws MissingBinaryError launch_sessions(config)
            end
        end
        @test occursin("sshpass, konsole",
                       sprint(showerror, MissingBinaryError(["sshpass", "konsole"])))
        @test occursin("bash", sprint(showerror, MissingBinaryError(["bash"])))
    end

    @testset "Command-line driver" begin
        parse = SshAutoLogin.parse_arguments
        @test parse(["--help"]).help
        @test parse(["-d", "-h"]).help
        options = parse(["--dry-run", "--config", "/cfg/x.toml"])
        @test !options.help
        @test options.dry_run
        @test options.config_path == "/cfg/x.toml"
        @test parse(["/cfg/positional.toml"]).config_path == "/cfg/positional.toml"
        defaults = parse(String[]; default_config="/cfg/default.toml")
        @test defaults.config_path == "/cfg/default.toml"
        @test !defaults.dry_run
        @test_throws ArgumentError parse(["--bogus"])
        @test_throws ArgumentError parse(["--config"])
        @test_throws ArgumentError parse(["--config", "--dry-run"])
        @test_throws ArgumentError parse(["a.toml", "b.toml"])
        @test_throws ArgumentError parse(["--config", "a.toml", "b.toml"])
        @test endswith(SshAutoLogin.default_config_path(), "config.toml")

        # main returns the status instead of exiting and writes to the given streams
        io = IOBuffer()
        err = IOBuffer()
        @test SshAutoLogin.main(["--help"]; io=io, err=err) == 0
        @test occursin("Usage:", String(take!(io)))
        @test isempty(take!(err))
        @test SshAutoLogin.main(["/nonexistent/config.toml"]; io=io, err=err) == 1
        @test isempty(take!(io))
        @test occursin("configuration file not found", String(take!(err)))
        @test SshAutoLogin.main(["--bogus"]; io=io, err=err) == 1
        @test occursin("unrecognized option '--bogus'", String(take!(err)))

        # A configuration error is printed without the exception type
        mktemp() do path, cfg
            write(cfg, "[[targets]]\n")
            close(cfg)
            chmod(path, 0o644)
            @test SshAutoLogin.main([path]; io=io, err=err) == 1
            @test startswith(String(take!(err)), "Error: Configuration file")
        end
    end

    @testset "Command-line scenarios" begin
        with_stub_environment(CONSUMING_KONSOLE) do _, runtime_dir
            mktempdir() do dir
                configs = Dict{String, String}()
                for (key, text) in ("tabs" => scenario_config("tabs"),
                                    "windows" => scenario_config("windows"),
                                    "malformed" => MALFORMED_CONFIG)
                    path = joinpath(dir, "config_$(key).toml")
                    write(path, text)
                    chmod(path, 0o600)
                    configs[key] = path
                end
                configs["missing"] = joinpath(dir, "does_not_exist.toml")

                scenarios = [(; arguments=["--config", configs["tabs"], "--dry-run"],
                              expected=0,
                              fragments=["konsole --separate --tabs-from-file",
                                         "<runtime-dir>/tabs.konsole"],
                              spawn=false,
                              description="a dry run prints the emulator command"),
                             (; arguments=["--config", configs["tabs"]], expected=0,
                              fragments=["Sessions dispatched", "emulator_processes = 1"],
                              spawn=false, description="tabs mode launches one window"),
                             (; arguments=["--config", configs["windows"]], expected=0,
                              fragments=["Sessions dispatched", "emulator_processes = 2"],
                              spawn=false,
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
                              fragments=["Sessions dispatched", "emulator_processes = 1"],
                              spawn=true,
                              description="scripts/run.jl forwards the arguments and the exit status")]

                for scenario in scenarios
                    @testset "$(scenario.description)" begin
                        outcome = invoke_driver(scenario.arguments; spawn=scenario.spawn)
                        @test outcome.exitcode == scenario.expected
                        @test !occursin(SCENARIO_PASSWORD, outcome.output)
                        for fragment in scenario.fragments
                            @test occursin(fragment, outcome.output)
                        end
                        # A launch that left wrappers behind warns and keeps or removes
                        # its directory; a completed one does neither.
                        # Checked after every scenario, before a later launch can purge
                        # a directory left behind. The warning is matched by its text:
                        # the spawned driver may also print warnings of Pkg about the
                        # manifest of the checkout.
                        if scenario.expected == 0
                            @test !occursin("every wrapper script", outcome.output)
                        end
                        launches = joinpath(runtime_dir, "ssh-autologin")
                        @test !isdir(launches) || isempty(readdir(launches))
                    end
                end

                # A launch failure is reported by the driver, without the exception type
                err = IOBuffer()
                withenv("XDG_RUNTIME_DIR" => nothing) do
                    @test SshAutoLogin.main([configs["tabs"]]; io=IOBuffer(), err=err) == 1
                end
                message = String(take!(err))
                @test occursin("Error: ", message) && occursin("XDG_RUNTIME_DIR", message)
                @test !occursin("ArgumentError", message)
                mktempdir() do empty_dir
                    withenv("PATH" => empty_dir) do
                        @test SshAutoLogin.main([configs["tabs"]]; io=IOBuffer(),
                                                err=err) == 1
                    end
                end
                message = String(take!(err))
                @test occursin("Required system binaries not found", message)
                @test !occursin("MissingBinaryError", message)
            end
        end
    end
end
