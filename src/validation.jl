const VALID_HOST_KEY_POLICIES = ("accept-new", "yes", "no")
const VALID_LOG_LEVELS = ("QUIET", "FATAL", "ERROR", "INFO", "VERBOSE", "DEBUG", "DEBUG1",
                          "DEBUG2", "DEBUG3")
const VALID_TERMINAL_MODES = (:tabs, :windows)
const VALID_TERMINAL_EMULATORS = ("konsole",)

"""
    HOSTNAME_PATTERN

RFC 1123 host name: dot-separated labels of letters, digits, and interior hyphens, each
at most 63 characters, optionally terminated by a dot. Dotted-decimal IPv4 addresses
match as well.
"""
const HOSTNAME_PATTERN = r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$"

"""
    IPV6_PATTERN

IPv6 literal made of colon-separated hexadecimal groups, optionally with an embedded
dotted-decimal IPv4 tail, with or without enclosing square brackets.
"""
const IPV6_PATTERN = r"^\[?(?=[0-9A-Fa-f:.]*[0-9A-Fa-f])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:\.[0-9]{1,3}){0,3}\]?$"

"""
    USERNAME_PATTERN

Account name: a letter or underscore followed by at most 31 letters, digits, dots,
underscores, or hyphens. The `@` character is excluded so that `user@host` stays
unambiguous.
"""
const USERNAME_PATTERN = r"^[A-Za-z_][A-Za-z0-9._-]{0,31}$"

const CONTROL_CHARACTER_PATTERN = r"[\x00-\x1f\x7f]"
const MAX_HOSTNAME_LENGTH = 253

"""
    is_valid_host(host::AbstractString)::Bool

Return whether `host` is an RFC 1123 host name, an IPv4 address, or an IPv6 literal.
"""
function is_valid_host(host::AbstractString)::Bool
    length(host) <= MAX_HOSTNAME_LENGTH || return false
    return occursin(HOSTNAME_PATTERN, host) || occursin(IPV6_PATTERN, host)
end

"""
    validate_target_fields(host, port, user, password, title, host_key_policy)

Validate the fields of an [`SshTarget`](@ref) against the constraints documented in
`config.example.toml`. Throws `ArgumentError` naming the offending field. Error messages
never contain the password.
"""
function validate_target_fields(host::AbstractString, port::Integer, user::AbstractString,
                                password::AbstractString, title::AbstractString,
                                host_key_policy::Union{Nothing, AbstractString})
    if !is_valid_host(host)
        throw(ArgumentError("SSH target 'host' ($(repr(host))) is not a valid host name, IPv4 address, or IPv6 literal."))
    end
    if !(1 <= port <= 65535)
        throw(ArgumentError("SSH target 'port' ($(port)) is outside the range [1, 65535]."))
    end
    if !occursin(USERNAME_PATTERN, user)
        throw(ArgumentError("SSH target 'user' ($(repr(user))) is not a valid account name: expected a letter or underscore followed by at most 31 letters, digits, '.', '_', or '-'."))
    end
    if isempty(password)
        throw(ArgumentError("SSH target 'password' for $(user)@$(host) must not be empty."))
    end
    if occursin(CONTROL_CHARACTER_PATTERN, password)
        throw(ArgumentError("SSH target 'password' for $(user)@$(host) must not contain control characters."))
    end
    if occursin(CONTROL_CHARACTER_PATTERN, title) || occursin(";;", title)
        throw(ArgumentError("SSH target 'title' ($(repr(title))) must not contain control characters or the sequence ';;'."))
    end
    if host_key_policy !== nothing && !(host_key_policy in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("SSH target 'strict_host_key_checking' ($(repr(host_key_policy))) must be one of $(VALID_HOST_KEY_POLICIES)."))
    end
    return nothing
end

"""
    validate_global_fields(connect_timeout, host_key_policy, log_level)

Validate the fields of a [`GlobalConfig`](@ref). Throws `ArgumentError` naming the
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
    if !(uppercase(log_level) in VALID_LOG_LEVELS)
        throw(ArgumentError("Global 'log_level' ($(repr(log_level))) must be one of $(VALID_LOG_LEVELS)."))
    end
    return nothing
end

"""
    validate_terminal_fields(emulator, mode, launch_settle_timeout)

Validate the fields of a [`TerminalOptions`](@ref). Throws `ArgumentError` naming the
offending field.
"""
function validate_terminal_fields(emulator::AbstractString, mode::Symbol,
                                  launch_settle_timeout::Real)
    if !(lowercase(emulator) in VALID_TERMINAL_EMULATORS)
        throw(ArgumentError("Terminal 'emulator' ($(repr(emulator))) is not supported; supported emulators: $(VALID_TERMINAL_EMULATORS)."))
    end
    if !(mode in VALID_TERMINAL_MODES)
        throw(ArgumentError("Terminal 'mode' (:$(mode)) must be one of $(VALID_TERMINAL_MODES)."))
    end
    if !(isfinite(launch_settle_timeout) && launch_settle_timeout > 0)
        throw(ArgumentError("Terminal 'launch_settle_timeout' ($(launch_settle_timeout)) must be a positive, finite number of seconds."))
    end
    return nothing
end
