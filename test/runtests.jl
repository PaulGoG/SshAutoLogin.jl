using Test
using SshAutoLogin
using Aqua
using JET
using ExplicitImports
import TOML

@testset "SshAutoLogin.jl" begin
    @testset "Static Code Quality Analysis (QA)" begin
        @testset "Aqua.jl" begin
            Aqua.test_all(SshAutoLogin)
        end

        @testset "JET.jl Static Analysis" begin
            JET.test_package(SshAutoLogin; target_modules = [SshAutoLogin])
        end

        @testset "ExplicitImports.jl" begin
            @test ExplicitImports.check_no_implicit_imports(SshAutoLogin) === nothing
            @test ExplicitImports.check_no_stale_explicit_imports(SshAutoLogin) === nothing
        end
    end

    @testset "Field Validation & Error Handling" begin
        # Valid construction
        t = SshTarget("192.168.1.10", 22, "admin", "secret", "My Node", "accept-new")
        @test t.host == "192.168.1.10"
        @test t.port == 22
        @test t.user == "admin"
        @test t.password == "secret"
        @test t.title == "My Node"
        @test t.strict_host_key_checking == "accept-new"

        # Default title derivation
        t_default_title = SshTarget("10.0.0.1", 2222, "root", "toor")
        @test t_default_title.title == "root@10.0.0.1:2222"

        # Target validation failures
        @test_throws ArgumentError SshTarget("", 22, "admin", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.1 0", 22, "admin", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 0, "admin", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 70000, "admin", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin user", "secret")
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "")
        @test_throws ArgumentError SshTarget(
            "192.168.1.10",
            22,
            "admin",
            "secret",
            "title",
            "invalid_policy",
        )

        # Global validation failures
        @test_throws ArgumentError GlobalConfig(0, "accept-new", "ERROR")
        @test_throws ArgumentError GlobalConfig(10, "invalid_policy", "ERROR")
        @test_throws ArgumentError GlobalConfig(10, "accept-new", "UNKNOWN_LEVEL")

        # Terminal validation failures
        @test_throws ArgumentError TerminalOptions("unsupported_term", :tabs, false)
        @test_throws ArgumentError TerminalOptions("konsole", :invalid_mode, false)
    end

    @testset "TOML Configuration Ingestion" begin
        toml_content = """
        [globals]
        connect_timeout = 15
        strict_host_key_checking = "yes"
        log_level = "DEBUG"

        [terminal]
        emulator = "konsole"
        mode = "tabs"
        hold = true

        [[targets]]
        host = "node01.cluster.local"
        port = 2201
        user = "scientist"
        password = "alpha_password"
        title = "Node 1"

        [[targets]]
        host = "node02.cluster.local"
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
            @test config.terminal.mode == :tabs
            @test config.terminal.hold == true
            @test length(config.targets) == 2

            t1 = config.targets[1]
            @test t1.host == "node01.cluster.local"
            @test t1.port == 2201
            @test t1.user == "scientist"
            @test t1.password == "alpha_password"
            @test t1.title == "Node 1"
            @test t1.strict_host_key_checking === nothing

            t2 = config.targets[2]
            @test t2.host == "node02.cluster.local"
            @test t2.port == 2202
            @test t2.user == "engineer"
            @test t2.password == "beta_password"
            @test t2.title == "engineer@node02.cluster.local:2202"
            @test t2.strict_host_key_checking == "accept-new"
        end

        # Missing target list
        @test_throws ArgumentError parse_config(Dict{String, Any}("globals" => Dict()))
        # Empty target list
        @test_throws ArgumentError parse_config(Dict{String, Any}("targets" => Any[]))
        # Missing required key in target
        @test_throws ArgumentError parse_config(
            Dict{String, Any}(
                "targets" => [Dict("host" => "192.168.1.1", "port" => 22, "user" => "root")],
            ),
        )
    end

    @testset "Runtime Directory & Self-Destructing Tab Scripts" begin
        globals = GlobalConfig(10, "accept-new", "ERROR")
        term_tabs = TerminalOptions("konsole", :tabs, false)
        term_windows = TerminalOptions("konsole", :windows, true)

        target1 = SshTarget("192.168.1.10", 22, "admin", "p@ssword1", "Primary Node")
        target2 = SshTarget("192.168.1.20", 2222, "guest", "p'ssword2", "Secondary Node", "no")

        # Runtime directory
        r_dir = get_runtime_directory()
        @test isdir(r_dir)

        # Clean runtime directory
        test_dummy = joinpath(r_dir, "dummy.txt")
        write(test_dummy, "test")
        @test isfile(test_dummy)
        clean_runtime_directory!(r_dir)
        @test !isfile(test_dummy)

        # Wrapper script generation with self-destruction
        script1 = generate_target_wrapper_script(target1, globals)
        @test occursin("rm -f -- \"\$0\"", script1)
        @test occursin("export SSHPASS='p@ssword1'", script1)
        @test occursin("StrictHostKeyChecking=accept-new", script1)
        @test occursin("admin@192.168.1.10", script1)

        # Quotes escaping in password
        script2 = generate_target_wrapper_script(target2, globals)
        @test occursin("rm -f -- \"\$0\"", script2)
        @test occursin("export SSHPASS='p'\\''ssword2'", script2)
        @test occursin("StrictHostKeyChecking=no", script2)
        @test occursin("guest@192.168.1.20", script2)

        # Tabs file generation
        wrapper_paths = ["/tmp/t1.sh", "/tmp/t2.sh"]
        tabs_str = generate_tabs_file_content([target1, target2], wrapper_paths)
        @test occursin("title: Primary Node ;; command: /tmp/t1.sh", tabs_str)
        @test occursin("title: Secondary Node ;; command: /tmp/t2.sh", tabs_str)

        # Tabs launch command
        config_tabs = SessionConfig(globals, term_tabs, [target1, target2])
        tab_cmd = build_tabs_launch_command(config_tabs, "/tmp/tabs.txt")
        @test tab_cmd.exec == ["konsole", "--nofork", "--tabs-from-file", "/tmp/tabs.txt"]

        # Windows mode command
        win_cmd = build_single_window_command(target1, globals, term_windows)
        @test win_cmd.exec[1] == "konsole"
        @test "--separate" in win_cmd.exec
        @test "--hold" in win_cmd.exec
        @test "-p" in win_cmd.exec
        @test "tabtitle=Primary Node" in win_cmd.exec
        @test "-e" in win_cmd.exec
        @test "sshpass" in win_cmd.exec
        @test win_cmd.env !== nothing
        @test any(startswith(e, "SSHPASS=") for e in win_cmd.env)

        # Launch all sessions in dry-run mode for tabs
        dry_run_tabs = launch_all_sessions(config_tabs; dry_run = true)
        @test length(dry_run_tabs) == 1
        @test dry_run_tabs[1].exec ==
              ["konsole", "--nofork", "--tabs-from-file", "<generated-tabs-file>"]

        # Launch all sessions in dry-run mode for windows
        config_windows = SessionConfig(globals, term_windows, [target1, target2])
        dry_run_wins = launch_all_sessions(config_windows; dry_run = true)
        @test length(dry_run_wins) == 2
        @test dry_run_wins[1] isa Cmd
        @test dry_run_wins[2] isa Cmd
    end
end
