#!/usr/bin/env julia
# Thin entry point: activates the package environment and runs SshAutoLogin.main.

include(joinpath(@__DIR__, "..", "activate.jl"))

using SshAutoLogin

exit(SshAutoLogin.main(ARGS))
