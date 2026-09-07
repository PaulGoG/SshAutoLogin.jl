"""
    SshTarget

Immutable description of one remote SSH endpoint.

# Fields
- `host::String`: host name, IPv4 address, or IPv6 literal.
- `port::Int`: SSH daemon port in `1:65535`.
- `user::String`: account name on the remote host.
- `password::String`: authentication password; never rendered by `show`.
- `title::String`: terminal tab or window title; defaults to `user@host:port`.
- `strict_host_key_checking::Union{Nothing, String}`: per-target host-key policy
  override, or `nothing` to inherit the global policy.

# Example
```julia
target = SshTarget("node01.cluster.local", 22, "scientist", "secret", "Node 01")
```
"""
struct SshTarget
    host::String
    port::Int
    user::String
    password::String
    title::String
    strict_host_key_checking::Union{Nothing, String}

    function SshTarget(host::AbstractString, port::Integer, user::AbstractString,
                       password::AbstractString, title::AbstractString="",
                       strict_host_key_checking::Union{Nothing, AbstractString}=nothing)
        validate_target_fields(host, port, user, password, title, strict_host_key_checking)
        resolved_title = isempty(title) ? "$(user)@$(host):$(port)" : String(title)
        policy = strict_host_key_checking === nothing ? nothing :
                 String(strict_host_key_checking)
        return new(String(host), Int(port), String(user), String(password), resolved_title,
                   policy)
    end
end

function Base.show(io::IO, target::SshTarget)
    print(io, "SshTarget(", repr(target.title), ", ", target.user, "@", target.host, ":",
          target.port, ", password = <redacted>")
    if target.strict_host_key_checking !== nothing
        print(io, ", strict_host_key_checking = ", repr(target.strict_host_key_checking))
    end
    return print(io, ")")
end

"""
    GlobalConfig

Connection parameters shared by all targets.

# Fields
- `connect_timeout::Int`: OpenSSH `ConnectTimeout` in seconds (positive).
- `strict_host_key_checking::String`: default host-key policy, one of `"accept-new"`,
  `"yes"`, `"no"`.
- `log_level::String`: OpenSSH `LogLevel`.
"""
struct GlobalConfig
    connect_timeout::Int
    strict_host_key_checking::String
    log_level::String

    function GlobalConfig(connect_timeout::Integer=10,
                          strict_host_key_checking::AbstractString="accept-new",
                          log_level::AbstractString="ERROR")
        validate_global_fields(connect_timeout, strict_host_key_checking, log_level)
        return new(Int(connect_timeout), String(strict_host_key_checking),
                   String(log_level))
    end
end

"""
    TerminalOptions

Terminal-emulator launch parameters.

# Fields
- `emulator::String`: emulator executable; only `"konsole"` is supported.
- `mode::Symbol`: `:tabs` (one window, one tab per target) or `:windows` (one window per
  target).
- `hold::Bool`: keep each tab open after the SSH session ends, waiting for a key press.
- `launch_settle_timeout::Float64`: seconds to wait for the emulator to consume the
  generated wrapper scripts before reporting a launch problem.
"""
struct TerminalOptions
    emulator::String
    mode::Symbol
    hold::Bool
    launch_settle_timeout::Float64

    function TerminalOptions(emulator::AbstractString="konsole",
                             mode::Union{Symbol, AbstractString}=:tabs, hold::Bool=false,
                             launch_settle_timeout::Real=30)
        resolved_mode = Symbol(mode)
        validate_terminal_fields(emulator, resolved_mode, launch_settle_timeout)
        return new(String(emulator), resolved_mode, hold, Float64(launch_settle_timeout))
    end
end

"""
    SessionConfig

Complete session description: global connection parameters, terminal options, and the
ordered list of targets (at least one).
"""
struct SessionConfig
    globals::GlobalConfig
    terminal::TerminalOptions
    targets::Vector{SshTarget}

    function SessionConfig(globals::GlobalConfig, terminal::TerminalOptions,
                           targets::AbstractVector{SshTarget})
        if isempty(targets)
            throw(ArgumentError("A session configuration must define at least one [[targets]] entry."))
        end
        return new(globals, terminal, SshTarget[t for t in targets])
    end
end
