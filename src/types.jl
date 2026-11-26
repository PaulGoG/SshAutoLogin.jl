"""
    default_title(host::AbstractString, port::Union{Nothing, Integer},
                  user::Union{Nothing, AbstractString})::String

Title of a target without an explicit one: `[user@]host[:port]`, each optional part
present when set.
"""
function default_title(host::AbstractString, port::Union{Nothing, Integer},
                       user::Union{Nothing, AbstractString})::String
    return (user === nothing ? "" : user * "@") * host *
           (port === nothing ? "" : ":$(port)")
end

"""
    SshTarget

One remote SSH endpoint.

# Fields
- `host::String`: host name, ssh_config `Host` alias, IPv4 address, or IPv6 literal.
- `port::Union{Nothing, Int}`: SSH daemon port in `1:65535`, or `nothing` to leave it to
  ~/.ssh/config or the `ssh` default.
- `user::Union{Nothing, String}`: account name on the remote host, or `nothing` to leave
  it to ~/.ssh/config or the local account name.
- `auth::Symbol`: `:password` (the password is supplied through `sshpass`) or `:key`
  (no secret is supplied; `ssh` authenticates with an agent, an identity file, a
  certificate, or an existing master connection, as ~/.ssh/config provides).
- `password::Union{Nothing, String}`: authentication password, set for `:password` only;
  never rendered by `show`.
- `identity_file::Union{Nothing, String}`: absolute path of a private key, or of a
  public key selecting an agent key, a leading `~/` expanded, for `:key` only; passed as
  `-i <path> -o IdentitiesOnly=yes`, so that no agent key outside the configured identity
  files is offered.
- `proxy_jump::Union{Nothing, String}`: `ssh -J` jump-host specification, for `:key`
  only, or `"none"` (any target) to connect directly whatever ~/.ssh/config routes.
- `title::String`: terminal tab or window title; defaults to `[user@]host[:port]`.
- `strict_host_key_checking::Union{Nothing, String}`: per-target host-key policy
  override, or `nothing` to inherit the global policy.

# Constructors
    SshTarget(host; port=nothing, user=nothing, auth=:password, password=nothing,
              identity_file=nothing, proxy_jump=nothing, title="",
              strict_host_key_checking=nothing)
    SshTarget(host, port, user, password, title="", strict_host_key_checking=nothing)

The positional form builds a password target. Both validate through
[`validate_target_fields`](@ref) and throw `ArgumentError` on invalid fields.

# Examples
```julia
target = SshTarget("node01.cluster.local", 22, "scientist", "secret", "Node 01")
cluster = SshTarget("hpc"; auth=:key)
```
"""
struct SshTarget
    host::String
    port::Union{Nothing, Int}
    user::Union{Nothing, String}
    auth::Symbol
    password::Union{Nothing, String}
    identity_file::Union{Nothing, String}
    proxy_jump::Union{Nothing, String}
    title::String
    strict_host_key_checking::Union{Nothing, String}

    function SshTarget(host::AbstractString; port::Union{Nothing, Integer}=nothing,
                       user::Union{Nothing, AbstractString}=nothing,
                       auth::Union{Symbol, AbstractString}=:password,
                       password::Union{Nothing, AbstractString}=nothing,
                       identity_file::Union{Nothing, AbstractString}=nothing,
                       proxy_jump::Union{Nothing, AbstractString}=nothing,
                       title::AbstractString="",
                       strict_host_key_checking::Union{Nothing, AbstractString}=nothing)
        # A string is compared before Symbol(), which throws on a NUL byte without naming the key
        if auth isa AbstractString && !(auth in ("password", "key"))
            throw(ArgumentError("SSH target 'auth' ($(repr(auth))) for $(target_label(host, user)) must be one of \"password\" or \"key\"."))
        end
        method = Symbol(auth)
        # A password target is refused for having identity_file at all, whatever its form
        key_path = identity_file === nothing || method != :key ? identity_file :
                   expand_identity_file(identity_file)
        validate_target_fields(host, port, user, method, password, key_path, proxy_jump,
                               title, strict_host_key_checking)
        resolved_title = isempty(title) ? default_title(host, port, user) : String(title)
        return new(String(host), port === nothing ? nothing : Int(port),
                   user === nothing ? nothing : String(user), method,
                   password === nothing ? nothing : String(password),
                   key_path === nothing ? nothing : String(key_path),
                   proxy_jump === nothing ? nothing : String(proxy_jump), resolved_title,
                   strict_host_key_checking === nothing ? nothing :
                   String(strict_host_key_checking))
    end
end

function SshTarget(host::AbstractString, port::Integer, user::AbstractString,
                   password::AbstractString, title::AbstractString="",
                   strict_host_key_checking::Union{Nothing, AbstractString}=nothing)
    return SshTarget(host; port, user, auth=:password, password, title,
                     strict_host_key_checking)
end

function Base.show(io::IO, target::SshTarget)
    print(io, "SshTarget(", repr(target.title), ", ",
          default_title(target.host, target.port, target.user), ", auth = ", target.auth)
    target.auth == :password && print(io, ", password = <redacted>")
    if target.identity_file !== nothing
        print(io, ", identity_file = ", repr(target.identity_file))
    end
    if target.proxy_jump !== nothing
        print(io, ", proxy_jump = ", repr(target.proxy_jump))
    end
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

Launch parameters of the terminal emulator, Konsole.

# Fields
- `mode::Symbol`: `:tabs` (one window, one tab per target) or `:windows` (one window per
  target).
- `hold::Bool`: keep each tab open after the SSH session ends, until Enter is pressed.
- `launch_settle_timeout::Float64`: seconds to wait for the emulator to consume the
  generated wrapper scripts before reporting a launch problem.
"""
struct TerminalOptions
    mode::Symbol
    hold::Bool
    launch_settle_timeout::Float64

    function TerminalOptions(mode::Union{Symbol, AbstractString}=:tabs, hold::Bool=false,
                             launch_settle_timeout::Real=30)
        resolved_mode = Symbol(mode)
        # Validated after the conversion: a huge or tiny Real becomes Inf or 0.0 here.
        timeout = Float64(launch_settle_timeout)
        validate_terminal_fields(resolved_mode, timeout)
        return new(resolved_mode, hold, timeout)
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
