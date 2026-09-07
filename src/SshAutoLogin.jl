module SshAutoLogin

using TOML: TOML

include("validation.jl")
include("types.jl")
include("config.jl")
include("process.jl")

export SshTarget,
       GlobalConfig,
       TerminalOptions,
       SessionConfig,
       MissingBinaryError,
       load_config,
       parse_config,
       validate_target_fields,
       validate_global_fields,
       validate_terminal_fields,
       is_valid_host,
       command_string,
       get_runtime_directory,
       clean_runtime_directory!,
       generate_target_wrapper_script,
       generate_tabs_file_content,
       build_tabs_launch_command,
       build_single_window_command,
       plan_sessions,
       launch_sessions

end # module SshAutoLogin
