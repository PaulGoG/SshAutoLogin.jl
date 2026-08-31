using Test
using SshAutoLogin
using Aqua
using JET
using ExplicitImports
using TOML: TOML

@testset "SshAutoLogin.jl" begin
    @testset "Static Code Quality Analysis (QA)" begin
        @testset "Aqua.jl" begin
            Aqua.test_all(SshAutoLogin)
        end

        @testset "JET.jl Static Analysis" begin
            JET.test_package(SshAutoLogin)
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
        @test_throws ArgumentError SshTarget("192.168.1.10", 22, "admin", "secret", "title",
                                             "invalid_policy")

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
        @test_throws ArgumentError parse_config(Dict{String, Any}("targets" =>
                                                                      [Dict("host" => "192.168.1.1",
                                                                            "port" => 22,
                                                                            "user" => "root")]))
    end

    @testset "Command Construction & Dry Run Dispatch" begin
        globals = GlobalConfig(10, "accept-new", "ERROR")
        term_tabs = TerminalOptions("konsole", :tabs, false)
        term_hold = TerminalOptions("konsole", :windows, true)

        target1 = SshTarget("192.168.1.10", 22, "admin", "p@ssword1", "Primary Node")
        target2 = SshTarget("192.168.1.20", 2222, "guest", "p@ssword2", "Secondary Node",
                            "no")

        # First tab command
        cmd1 = build_terminal_command(target1, globals, term_tabs; is_first=true)
        cmd1_args = cmd1.exec
        @test cmd1_args[1] == "konsole"
        @test !("--new-tab" in cmd1_args)
        @test "-p" in cmd1_args
        @test "tabtitle=Primary Node" in cmd1_args
        @test "-e" in cmd1_args
        @test "sshpass" in cmd1_args
        @test "StrictHostKeyChecking=accept-new" in cmd1_args
        @test "admin@192.168.1.10" in cmd1_args
        @test cmd1.env !== nothing
        @test any(startswith(e, "SSHPASS=") for e in cmd1.env)

        # Subsequent tab command (should include --new-tab)
        cmd2 = build_terminal_command(target2, globals, term_tabs; is_first=false)
        cmd2_args = cmd2.exec
        @test cmd2_args[1] == "konsole"
        @test "--new-tab" in cmd2_args
        @test "StrictHostKeyChecking=no" in cmd2_args
        @test "guest@192.168.1.20" in cmd2_args

        # Windows mode with hold enabled
        cmd_hold = build_terminal_command(target1, globals, term_hold; is_first=false)
        @test !("--new-tab" in cmd_hold.exec)
        @test "--hold" in cmd_hold.exec

        # Launch all sessions in dry-run mode
        config = SessionConfig(globals, term_tabs, [target1, target2])
        dry_run_cmds = launch_all_sessions(config; dry_run=true)
        @test length(dry_run_cmds) == 2
        @test dry_run_cmds[1] isa Cmd
        @test dry_run_cmds[2] isa Cmd
    end
end
