using Pkg

# add dependencies
# ----------------

package_dir = normpath(joinpath(@__DIR__, ".."))
junojl_file = joinpath(package_dir, "src", "Juno.jl")
project_file = joinpath(package_dir, "Project.toml")
test_file = joinpath(package_dir, "test", "runtests.jl")
precompile_file = joinpath(package_dir, "src", "precompile.jl")

lines = readlines(junojl_file; keep = true)

toml = Pkg.TOML.parsefile(project_file)
test_deps = get(toml, "extras", nothing)

@info "Adding temporary dependencies ..."
test_deps !== nothing && Pkg.add([PackageSpec(; name = name, uuid = uuid) for (name, uuid) in test_deps])
Pkg.add("SnoopCompile")

# generate and assert
# -------------------

using SnoopCompile

try
    @info "Generating `precompile` statements ..."
    try
        open(junojl_file, "w") do io
            for line in lines
                if occursin("_precompile_()", line)
                    write(io, "# _precompile_()\n") # comment out
                else
                    write(io, line)
                end
            end
        end
        @debug "Commented out `_precompile_` call in $junojl_file for `precompile` statement generation"

        inf_timing = @snoopi include(test_file)
        pc = SnoopCompile.parcel(inf_timing; blacklist=["Main"]) # NOTE: don't include functions used in test

        if (stmts = get(pc, :Juno, nothing)) !== nothing
            open(precompile_file, "w") do io
                println(io, "# This file is mostly generated by `scripts/generate_precompile.jl`\n")
                if any(str->occursin("__lookup", str), stmts)
                    println(io, SnoopCompile.lookup_kwbody_str)
                end
                println(io, "function _precompile_()")
                println(io, "    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing")
                for stmt in sort(stmts)
                    if startswith(stmt, "isdefined")
                        println(io, "    try; $stmt; catch err; @debug err; end") # don't assert on this
                    else
                        println(io, "    try; @assert $stmt; catch err; @debug err; end")
                    end
                end
                println(io, "end")
            end
        end
    catch e
        printstyled(
            "`precompile` statement generation failed with the following error:\n";
            bold = true, color = :lightred
        )
        @error e
    end

    @info "Asserting generated statements ..."
    try
        open(junojl_file, "w") do io
            for line in lines
                if occursin("# _precompile_()", line)
                    write(io, "_precompile_()\n") # comment in
                else
                    write(io, line)
                end
            end
        end
        @debug "Commented in `_precompile_` call in $junojl_file for `precompile` statement assertion"

        run(pipeline(`julia --project=. --color=yes -e '
            ENV["JULIA_DEBUG"] = "Juno"
            using Juno # should invoke precompile
        '`))
    catch e
        printstyled(
            "`precompile` statement assertion failed with the following error:\n";
            bold = true, color = :lightred
        )
        @error e
    finally
        # let lines = readlines(precompile_file; keep = true)
        #     open(precompile_file, "w") do io
        #         for line in lines
        #             write(io, replace(line, "@assert " => ""))
        #         end
        #     end
        # end
        # @info "Removed `@assert`s in $precompile_file"
    end
catch e
    printstyled(
        "Unexpected error happened:\n";
        bold = true, color = :lightred
    )
    @error e
finally
    open(junojl_file, "w") do io
        for line in lines
            write(io, line)
        end
    end
    @info "Restored the original state in $junojl_file"
end

# remove dependencies
# -------------------

@info "Removing temporary dependencies ..."
test_deps === nothing || Pkg.rm([PackageSpec(; name = name, uuid = uuid) for (name, uuid) in test_deps])
Pkg.rm("SnoopCompile")
