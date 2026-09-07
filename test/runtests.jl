using Test
using SshAutoLogin
using Aqua
using JET
using ExplicitImports
using JuliaFormatter

# Characters that must survive shell quoting unchanged.
const AWKWARD_PASSWORD = "p'ss#w\$ord`1 -x"

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
if [ "\$1" = "--nofork" ] && [ "\$2" = "--tabs-from-file" ]; then
    sed -n 's/.*;; command: //p' "\$3" | while read -r command; do
        "\$command" </dev/null >/dev/null 2>&1
    done
elif [ "\$1" = "--separate" ]; then
    "\$5" </dev/null >/dev/null 2>&1
fi
exit 0
"""

# Stub emulator that fails before opening anything.
const FAILING_KONSOLE = "#!/bin/sh\nexit 3\n"

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

@testset "SshAutoLogin.jl" begin
    @testset "Static analysis" begin
        Aqua.test_all(SshAutoLogin)
        JET.test_package(SshAutoLogin; target_modules=[SshAutoLogin])
        @test ExplicitImports.check_no_implicit_imports(SshAutoLogin) === nothing
        @test ExplicitImports.check_no_stale_explicit_imports(SshAutoLogin) === nothing
    end

    @testset "Formatting" begin
        @test JuliaFormatter.format(pkgdir(SshAutoLogin); overwrite=false)
    end

    @testset "Field validation" begin
        for host in ("node01.cluster.local", "192.168.1.10", "localhost", "a-b.c.", "::1",
                     "[2001:db8::1]", "2001:db8::1", "::ffff:192.0.2.1")
            @test is_valid_host(host)
        end
        for host in ("", "host name", "bad_host!", "-leading.dash", "a..b", ":", "::",
                     "a"^254, "host;rm -rf /")
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
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "a\nb")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "secret",
                                             "A ;; B")
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
        @test_throws ArgumentError TerminalOptions("xterm", :tabs, false)
        @test_throws ArgumentError TerminalOptions("konsole", :panes, false)
        @test_throws ArgumentError TerminalOptions("konsole", :tabs, false, 0)
        @test_throws ArgumentError TerminalOptions("konsole", :tabs, false, Inf)
        @test TerminalOptions().launch_settle_timeout == 30.0
        @test TerminalOptions("konsole", "windows", true, 5).mode == :windows
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

    @testset "TOML configuration ingestion" begin
        toml_content = """
        [globals]
        connect_timeout = 15
        strict_host_key_checking = "yes"
        log_level = "DEBUG"

        [terminal]
        emulator = "konsole"
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

        wrong_type = merge(base_target, Dict{String, Any}("port" => "22"))
        err = captured_error(() -> parse_config(Dict{String,
                                                     Any}("targets" => Any[wrong_type])))
        @test err isa ArgumentError
        @test occursin("port", sprint(showerror, err))

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
        @test_throws ArgumentError load_config(joinpath(tempdir(), "does-not-exist.toml"))
    end

    @testset "Wrapper scripts and emulator commands" begin
        globals = GlobalConfig(10, "accept-new", "ERROR")
        target1 = SshTarget("192.168.1.10", 22, "admin", "plain1", "Primary Node")
        target2 = SshTarget("192.168.1.20", 2222, "guest", AWKWARD_PASSWORD,
                            "Secondary Node",
                            "no")

        script = generate_target_wrapper_script(target2, globals)
        @test startswith(script, "#!/usr/bin/env bash\n")
        @test occursin("rm -f -- \"\$0\"", script)
        @test occursin("exec 3< <(printf -- '%s\\n' " *
                       Base.shell_escape_posixly(AWKWARD_PASSWORD) * ")", script)
        @test occursin("exec sshpass -d 3 ssh -p 2222 -o StrictHostKeyChecking=no " *
                       "-o ConnectTimeout=10 -o LogLevel=ERROR -o NumberOfPasswordPrompts=1 " *
                       "'guest@192.168.1.20'", script)
        @test !occursin("SSHPASS", script)

        hold_script = generate_target_wrapper_script(target1, globals; hold=true)
        @test occursin("status=\$?", hold_script)
        @test occursin("read -r _", hold_script)
        @test !occursin("exec sshpass", hold_script)

        # The wrapper delivers the exact password over file descriptor 3 and removes itself.
        mktempdir() do dir
            write_executable(joinpath(dir, "sshpass"), "#!/bin/sh\ncat <&3\n")
            wrapper = write_executable(joinpath(dir, "target.sh"), script)
            delivered = withenv("PATH" => dir * ":" * ENV["PATH"]) do
                return read(`$(wrapper)`, String)
            end
            @test delivered == AWKWARD_PASSWORD * "\n"
            @test !isfile(wrapper)
        end

        tabs = generate_tabs_file_content([target1, target2], ["/run/t1.sh", "/run/t2.sh"])
        @test tabs ==
              "title: Primary Node ;; command: /run/t1.sh\ntitle: Secondary Node ;; command: /run/t2.sh\n"
        @test_throws DimensionMismatch generate_tabs_file_content([target1], String[])

        config_tabs = SessionConfig(globals, TerminalOptions("konsole", :tabs, false),
                                    [target1, target2])
        @test build_tabs_launch_command(config_tabs, "/run/tabs.konsole").exec ==
              ["konsole", "--nofork", "--tabs-from-file", "/run/tabs.konsole"]
        window = build_single_window_command(target1,
                                             TerminalOptions("konsole", :windows, true),
                                             "/run/t1.sh")
        @test window.exec ==
              ["konsole", "--separate", "-p", "tabtitle=Primary Node", "-e", "/run/t1.sh"]
        @test window.env === nothing
        @test command_string(window) ==
              "konsole --separate -p 'tabtitle=Primary Node' -e /run/t1.sh"

        plan = plan_sessions(config_tabs)
        @test length(plan) == 1
        @test plan[1].exec[end] == "<runtime-dir>/tabs.konsole"
        config_windows = SessionConfig(globals, TerminalOptions("konsole", :windows, true),
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
                dir = get_runtime_directory()
                @test dir == joinpath(runtime_dir, "ssh-autologin")
                @test isdir(dir)
                @test (filemode(dir) & 0o777) == 0o700
                marker = joinpath(dir, "stale.sh")
                write(marker, "x")
                clean_runtime_directory!(dir)
                @test isdir(dir)
                @test !isfile(marker)
            end
        end
        fallback = withenv("XDG_RUNTIME_DIR" => nothing) do
            return @test_logs (:warn, r"XDG_RUNTIME_DIR") get_runtime_directory()
        end
        @test isdir(fallback)
        @test (filemode(fallback) & 0o777) == 0o700
        rm(fallback; recursive=true)
    end

    @testset "Launch with stub emulator" begin
        globals = GlobalConfig()
        targets = [SshTarget("10.0.0.1", 22, "admin", "p1", "Node A"),
                   SshTarget("10.0.0.2", 22, "admin", AWKWARD_PASSWORD, "Node B")]

        for terminal in (TerminalOptions("konsole", :tabs, false, 5),
                         TerminalOptions("konsole", :windows, true, 5))
            config = SessionConfig(globals, terminal, targets)
            with_stub_environment(CONSUMING_KONSOLE) do _, runtime_dir
                processes = launch_sessions(config)
                @test length(processes) == (terminal.mode == :tabs ? 1 : 2)
                foreach(wait, processes)
                @test all(p -> p.exitcode == 0, processes)
                @test isempty(readdir(joinpath(runtime_dir, "ssh-autologin")))
            end
        end

        # An emulator that exits without executing the wrappers: warning, files retained.
        config = SessionConfig(globals, TerminalOptions("konsole", :tabs, false, 5),
                               targets)
        with_stub_environment(FAILING_KONSOLE) do _, runtime_dir
            processes = @test_logs (:warn, r"settle timeout") match_mode=:any launch_sessions(config)
            wait(processes[1])
            @test processes[1].exitcode == 3
            session_dir = joinpath(runtime_dir, "ssh-autologin")
            remaining = readdir(session_dir)
            @test "target_1.sh" in remaining
            @test "target_2.sh" in remaining
            @test "tabs.konsole" in remaining
            @test (filemode(joinpath(session_dir, "target_1.sh")) & 0o777) == 0o700
            @test (filemode(joinpath(session_dir, "tabs.konsole")) & 0o777) == 0o600
        end

        mktempdir() do empty_dir
            withenv("PATH" => empty_dir) do
                @test_throws MissingBinaryError launch_sessions(config)
            end
        end
        @test occursin("sshpass, konsole",
                       sprint(showerror, MissingBinaryError(["sshpass", "konsole"])))
    end
end
