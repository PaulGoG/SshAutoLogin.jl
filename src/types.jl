"""
    SshTarget

Immutable specification of a single remote SSH target endpoint.

# Fields
- `host::String`: Target hostname or IPv4/IPv6 address.
- `port::Int`: Remote SSH daemon port (bounded in `1:65535`).
- `user::String`: Authentication username.
- `password::String`: Authentication password.
- `title::String`: Terminal tab/window title.
- `strict_host_key_checking::Union{Nothing, String}`: Target-specific host key policy override.
"""
struct SshTarget
    host::String
    port::Int
    user::String
    password::String
    title::String
    strict_host_key_checking::Union{Nothing, String}

    function SshTarget(host::AbstractString,
                       port::Integer,
                       user::AbstractString,
                       password::AbstractString,
                       title::AbstractString="",
                       strict_host_key_checking::Union{Nothing, AbstractString}=nothing)
        validate_target_fields(host, port, user, password, strict_host_key_checking)
        resolved_title = isempty(title) ? "$(user)@$(host):$(port)" : String(title)
        return new(String(host),
                   Int(port),
                   String(user),
                   String(password),
                   resolved_title,
                   strict_host_key_checking === nothing ? nothing :
                   String(strict_host_key_checking))
    end
end

function Base.:(==)(a::SshTarget, b::SshTarget)
    return a.host == b.host &&
           a.port == b.port &&
           a.user == b.user &&
           a.password == b.password &&
           a.title == b.title &&
           a.strict_host_key_checking == b.strict_host_key_checking
end

function Base.isless(a::SshTarget, b::SshTarget)
    return a.host == b.host ? (a.port == b.port ? a.user < b.user : a.port < b.port) :
           a.host < b.host
end

"""
    GlobalConfig

Global operational parameters governing SSH connections.

# Fields
- `connect_timeout::Int`: Connection establishment timeout in seconds.
- `strict_host_key_checking::String`: Default host key verification policy (`"accept-new"`, `"yes"`, `"no"`).
- `log_level::String`: OpenSSH logging verbosity level.
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

Configuration for the desktop terminal emulator window manager.

# Fields
- `emulator::String`: Binary name of the terminal emulator (default: `"konsole"`).
- `mode::Symbol`: Window aggregation mode (`:tabs` or `:windows`).
- `hold::Bool`: Whether to retain the terminal open after child process exit.
"""
struct TerminalOptions
    emulator::String
    mode::Symbol
    hold::Bool

    function TerminalOptions(emulator::AbstractString="konsole",
                             mode::Union{Symbol, AbstractString}=:tabs,
                             hold::Bool=false)
        resolved_mode = Symbol(mode)
        validate_terminal_fields(emulator, resolved_mode)
        return new(String(emulator), resolved_mode, hold)
    end
end

"""
    SessionConfig

Complete session configuration aggregating globals, terminal settings, and targets.

# Fields
- `globals::GlobalConfig`: Global connection options.
- `terminal::TerminalOptions`: Terminal manager options.
- `targets::Vector{SshTarget}`: Ordered list of remote SSH endpoints.
"""
struct SessionConfig
    globals::GlobalConfig
    terminal::TerminalOptions
    targets::Vector{SshTarget}

    function SessionConfig(globals::GlobalConfig,
                           terminal::TerminalOptions,
                           targets::Vector{SshTarget})
        if isempty(targets)
            throw(ArgumentError("Session configuration must define at least one [[targets]] entry."))
        end
        return new(globals, terminal, targets)
    end
end

function SessionConfig(globals::GlobalConfig,
                       terminal::TerminalOptions,
                       targets::AbstractVector{SshTarget})
    return SessionConfig(globals, terminal, SshTarget[t for t in targets])
end
