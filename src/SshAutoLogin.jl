module SshAutoLogin

using Logging: ConsoleLogger, with_logger
using TOML: TOML

include("validation.jl")
include("types.jl")
include("config.jl")
include("process.jl")
include("cli.jl")

export SshTarget,
       GlobalConfig,
       TerminalOptions,
       SessionConfig,
       MissingBinaryError,
       load_config,
       parse_config,
       plan_sessions,
       launch_sessions

# `main` is the public command-line driver; it is not exported so that `using` never
# places a `main` in Main.
VERSION >= v"1.11" && eval(Expr(:public, :main))

end # module SshAutoLogin
