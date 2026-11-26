const VALID_HOST_KEY_POLICIES = ("accept-new", "yes", "no")
const VALID_LOG_LEVELS = ("QUIET", "FATAL", "ERROR", "INFO", "VERBOSE", "DEBUG", "DEBUG1",
                          "DEBUG2", "DEBUG3")
const VALID_TERMINAL_MODES = (:tabs, :windows)
const VALID_AUTH_METHODS = (:password, :key)

# The patterns end in \z, not $, which would also match before a final newline.
"""
    HOSTNAME_PATTERN

RFC 1123 host name extended by `_`, which ssh_config `Host` aliases may contain:
dot-separated labels of letters, digits, `_`, and interior hyphens, each at most 63
characters, optionally terminated by a dot. Dotted-decimal IPv4 addresses match as well.
A leading `-` never matches, so a host is never read as an `ssh` option.
"""
const HOSTNAME_PATTERN = r"^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*\.?\z"

"""
    IPV6_PATTERN

IPv6 literal made of colon-separated hexadecimal groups, optionally with an embedded
dotted-decimal IPv4 tail. Square brackets are not accepted: `ssh` does not strip them
from `user@host`.
"""
const IPV6_PATTERN = r"^(?=[0-9A-Fa-f:.]*[0-9A-Fa-f])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:\.[0-9]{1,3}){0,3}\z"

"""
    USERNAME_PATTERN

Account name: a letter or underscore followed by at most 31 letters, digits, dots,
underscores, or hyphens. The `@` character is excluded so that `user@host` stays
unambiguous.
"""
const USERNAME_PATTERN = r"^[A-Za-z_][A-Za-z0-9._-]{0,31}\z"

const CONTROL_CHARACTER_PATTERN = r"[\x00-\x1f\x7f]"
const MAX_HOSTNAME_LENGTH = 253

# One hop of an `ssh -J` specification: [user@]host[:port], IPv6 hosts in brackets.
const PROXY_JUMP_HOP_PATTERN = r"^(?:(?<user>[^@]+)@)?(?<host>\[[^\]]+\]|[^:\[\]@]+)(?::(?<port>[0-9]{1,5}))?\z"

"""
    is_valid_host(host::AbstractString)::Bool

Return whether `host` is an RFC 1123 host name, an ssh_config `Host` alias, an IPv4
address, or an IPv6 literal.
"""
function is_valid_host(host::AbstractString)::Bool
    length(host) <= MAX_HOSTNAME_LENGTH || return false
    return occursin(HOSTNAME_PATTERN, host) || occursin(IPV6_PATTERN, host)
end

"""
    target_label(host::AbstractString, user::Union{Nothing, AbstractString})::String

Destination as `ssh` receives it: `user@host`, or `host` alone when `user` is `nothing`
and ssh_config or the local account name supplies it. Used in messages and as the last
argument of the `ssh` command.
"""
function target_label(host::AbstractString, user::Union{Nothing, AbstractString})::String
    return user === nothing ? String(host) : "$(user)@$(host)"
end

"""
    is_valid_proxy_jump(spec::AbstractString)::Bool

Return whether `spec` is a jump-host specification accepted for `ssh -J`: one or more
`[user@]host[:port]` hops separated by commas, an IPv6 host enclosed in square brackets,
or exactly `none`, which disables a `ProxyJump` or `ProxyCommand` set in ~/.ssh/config.
Each user must be a valid account name, each host a valid host name, alias, or IPv4
address (an IPv6 literal only in brackets), and each port lie in `1:65535`. Empty
specifications and hops, control characters, and `ssh://` URIs are refused. A bracketed
IPv6 host is accepted in the last hop only: OpenSSH hands the hops before the last to
`/bin/sh` unquoted, inside the command it builds for the last jump host, and the shell
would read the brackets as a glob pattern.
"""
function is_valid_proxy_jump(spec::AbstractString)::Bool
    spec == "none" && return true
    occursin(CONTROL_CHARACTER_PATTERN, spec) && return false
    hops = split(spec, ',')
    for (index, hop) in enumerate(hops)
        m = match(PROXY_JUMP_HOP_PATTERN, hop)
        m === nothing && return false
        user = m[:user]
        if user !== nothing && !occursin(USERNAME_PATTERN, user)
            return false
        end
        # The host group is not optional: it captured whenever the hop matched.
        host = m[:host]::AbstractString
        if startswith(host, '[')
            index == length(hops) || return false
            occursin(IPV6_PATTERN, chop(host; head=1, tail=1)) || return false
        elseif occursin(':', host) || !is_valid_host(host)
            return false
        end
        port = m[:port]
        if port !== nothing
            number = tryparse(Int, port)
            (number !== nothing && 1 <= number <= 65535) || return false
        end
    end
    return true
end

"""
    expand_identity_file(path::AbstractString)::String

Expand a leading `~` of `path` to the home directory, as `expanduser` does. A path that
starts with `~` followed by anything but `/` (`~user/...`) is refused with an
`ArgumentError` naming the key, since only the own home directory is expanded.
"""
function expand_identity_file(path::AbstractString)::String
    if startswith(path, '~') && !(path == "~" || startswith(path, "~/"))
        throw(ArgumentError("SSH target 'identity_file' ($(repr(path))) may start with '~/', but not with '~user': only the own home directory is expanded."))
    end
    return expanduser(path)
end

"""
    validate_identity_file(path::AbstractString)

Check that `path`, already expanded by [`expand_identity_file`](@ref), names a key file
that `ssh` will open as given: free of control characters, of `%` and `\$`, which `ssh`
expands in an identity path (`%d`, `\${HOME}`) after the check made here, absolute, and a
regular file. A private key must have no group or other permission bits, which `ssh`
refuses for a key of its owner; a public key (`.pub`), which selects the key of an agent
or a security token, is exempt. The file content is never read. Returns `nothing`; throws
`ArgumentError` naming the violated condition, also when the path cannot be inspected.
"""
function validate_identity_file(path::AbstractString)
    if occursin(CONTROL_CHARACTER_PATTERN, path)
        throw(ArgumentError("SSH target 'identity_file' must not contain control characters."))
    end
    if occursin('%', path) || occursin('$', path)
        throw(ArgumentError("SSH target 'identity_file' ($(repr(path))) must not contain '%' or '\$': ssh expands them in an identity path and would open another file."))
    end
    if !startswith(path, '/')
        throw(ArgumentError("SSH target 'identity_file' ($(repr(path))) must be an absolute path or start with '~'."))
    end
    # The ArgumentError is thrown outside the catch block so that no cause is chained.
    failure = nothing
    present = try
        isfile(path)
    catch err
        err isa Base.IOError || rethrow()
        failure = err
        false
    end
    # libuv reports an error as the negated errno on Unix.
    if failure !== nothing
        throw(ArgumentError("SSH target 'identity_file' ($(repr(path))) cannot be inspected: $(Libc.strerror(-failure.code))."))
    end
    if !present
        throw(ArgumentError("SSH target 'identity_file' ($(repr(path))) is not a regular file."))
    end
    mode = filemode(path) & 0o777
    if !endswith(path, ".pub") && mode & 0o077 != 0
        throw(ArgumentError("SSH target 'identity_file' ($(repr(path))) is accessible to group or others (mode $(string(mode; base=8, pad=3))); ssh refuses such a private key: chmod 600 $(repr(path))"))
    end
    return nothing
end

"""
    validate_target_fields(host, port, user, auth, password, identity_file, proxy_jump,
                           title, host_key_policy)

Validate the fields of an [`SshTarget`](@ref). `port` and `user` are checked only when
set. `auth` must be `:password` or `:key`. A password target requires a non-empty
`password` free of control characters, admits no `identity_file`, and admits
`proxy_jump` only as `"none"`; a key target admits no `password`, an `identity_file` that passes
[`validate_identity_file`](@ref), and a `proxy_jump` that passes
[`is_valid_proxy_jump`](@ref). Throws `ArgumentError` naming the offending field. Error
messages never contain the password.
"""
function validate_target_fields(host::AbstractString, port::Union{Nothing, Integer},
                                user::Union{Nothing, AbstractString}, auth::Symbol,
                                password::Union{Nothing, AbstractString},
                                identity_file::Union{Nothing, AbstractString},
                                proxy_jump::Union{Nothing, AbstractString},
                                title::AbstractString,
                                host_key_policy::Union{Nothing, AbstractString})
    if !is_valid_host(host)
        throw(ArgumentError("SSH target 'host' ($(repr(host))) is not a valid host name, IPv4 address, or IPv6 literal."))
    end
    if port !== nothing && !(1 <= port <= 65535)
        throw(ArgumentError("SSH target 'port' ($(port)) is outside the range [1, 65535]."))
    end
    if user !== nothing && !occursin(USERNAME_PATTERN, user)
        throw(ArgumentError("SSH target 'user' ($(repr(user))) is not a valid account name: expected a letter or underscore followed by at most 31 letters, digits, '.', '_', or '-'."))
    end
    label = target_label(host, user)
    if !(auth in VALID_AUTH_METHODS)
        throw(ArgumentError("SSH target 'auth' ($(repr(String(auth)))) for $(label) must be one of \"password\" or \"key\"."))
    end
    if auth == :password
        if password === nothing
            throw(ArgumentError("SSH target $(label) has auth = \"password\" but no 'password'."))
        end
        if isempty(password)
            throw(ArgumentError("SSH target 'password' for $(label) must not be empty."))
        end
        if occursin(CONTROL_CHARACTER_PATTERN, password)
            throw(ArgumentError("SSH target 'password' for $(label) must not contain control characters."))
        end
        if identity_file !== nothing
            throw(ArgumentError("SSH target 'identity_file' for $(label) applies to auth = \"key\" only."))
        end
        if proxy_jump !== nothing && proxy_jump != "none"
            throw(ArgumentError("SSH target 'proxy_jump' for $(label) is not available with auth = \"password\" except as \"none\": sshpass answers the first password prompt it sees, and a jump host asking for a password would receive the target's password. Use auth = \"key\"."))
        end
    else
        if password !== nothing
            throw(ArgumentError("SSH target 'password' for $(label) must not be set with auth = \"key\"."))
        end
        identity_file === nothing || validate_identity_file(identity_file)
        if proxy_jump !== nothing && !is_valid_proxy_jump(proxy_jump)
            throw(ArgumentError("SSH target 'proxy_jump' ($(repr(proxy_jump))) for $(label) must be one or more [user@]host[:port] hops separated by commas, an IPv6 address in brackets only in the last hop, or \"none\"."))
        end
    end
    if occursin(CONTROL_CHARACTER_PATTERN, title) || occursin(';', title) ||
       occursin('%', title)
        throw(ArgumentError("SSH target 'title' ($(repr(title))) must not contain control characters, ';', or '%': Konsole splits profile properties on ';' and expands '%' sequences in tab titles."))
    end
    if host_key_policy !== nothing && !(host_key_policy in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("SSH target 'strict_host_key_checking' ($(repr(host_key_policy))) must be one of $(VALID_HOST_KEY_POLICIES)."))
    end
    return nothing
end

"""
    validate_global_fields(connect_timeout, host_key_policy, log_level)

Validate the fields of a [`GlobalConfig`](@ref). Enumerated values must match exactly,
in the spelling documented in `config.example.toml`. Throws `ArgumentError` naming the
offending field.
"""
function validate_global_fields(connect_timeout::Integer, host_key_policy::AbstractString,
                                log_level::AbstractString)
    if connect_timeout <= 0
        throw(ArgumentError("Global 'connect_timeout' ($(connect_timeout)) must be a positive integer number of seconds."))
    end
    if !(host_key_policy in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("Global 'strict_host_key_checking' ($(repr(host_key_policy))) must be one of $(VALID_HOST_KEY_POLICIES)."))
    end
    if !(log_level in VALID_LOG_LEVELS)
        throw(ArgumentError("Global 'log_level' ($(repr(log_level))) must be one of $(VALID_LOG_LEVELS)."))
    end
    return nothing
end

"""
    validate_terminal_fields(mode, launch_settle_timeout)

Validate the fields of a [`TerminalOptions`](@ref). Throws `ArgumentError` naming the
offending field.
"""
function validate_terminal_fields(mode::Symbol, launch_settle_timeout::Real)
    if !(mode in VALID_TERMINAL_MODES)
        throw(ArgumentError("Terminal 'mode' (:$(mode)) must be one of $(VALID_TERMINAL_MODES)."))
    end
    if !(isfinite(launch_settle_timeout) && launch_settle_timeout > 0)
        throw(ArgumentError("Terminal 'launch_settle_timeout' ($(launch_settle_timeout)) must be a positive, finite number of seconds."))
    end
    return nothing
end
