module StartupPackage

export @startup

const PKG = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")
const REVISE = Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")

"The task that loads the generated package in the background, or `nothing`."
const LOADING = Ref{Union{Nothing, Task}}(nothing)

"""
    @startup [name = "Startup"] [urls = ["Name" => "url", ...]] begin ... end

Load the body as a precompiled package, asynchronously in an interactive session, installing missing dependencies.

The generated package lives in `joinpath(first(DEPOT_PATH), "config", name)` without a `Project.toml`, so it loads
its dependencies from the environments in `LOAD_PATH`. It includes the file with the `@startup` call, keeping only
the body of the call. Statements that define something, call `precompile` or declare the type of a global in a scope
stay at top level, so that the package caches their results. All others run in `__init__` in source order, see
[`StartupPackage.separate`](@ref). The package exports all names it defines, assigns or imports and is loaded with
`using` in `Main`, in an interactive session in the background once the REPL shows its prompt, see
[`StartupPackage.load`](@ref). A global that functions in the body use, but that the package does not define,
resolves to the global of the same name in `Main`. So names that `Main` gets later, such as autoloaded ones, work as
in a plain `startup.jl`.

The packages named in `using` and `import` anywhere in the body, quoted expressions included, become the dependencies
of the generated package. Whenever the file changed since the last check by the running Julia minor version, the
missing ones are added to the default environment `@v#.#` in one `Pkg.add` call, unregistered ones from their URL in
`urls`.

`using StartupPackage` must be a separate top-level statement before the `@startup` call, because Julia expands the
macros of a top-level expression before running any part of it. The README shows the setup of `startup.jl` and lists
the limitations.
"""
macro startup(args...)
    body = isempty(args) ? nothing : last(args)
    Meta.isexpr(body, :block) || throw(ArgumentError("`@startup` needs a `begin ... end` block as last argument"))
    string_pair(@nospecialize(ex)) =
        Meta.isexpr(ex, :call, 3) && ex.args[1] === :(=>) && all(arg -> arg isa String, ex.args[2:3])
    name = "Startup"
    urls = Pair{String, String}[]
    for option in args[begin:end - 1]
        key, value = Meta.isexpr(option, :(=), 2) ? option.args : (nothing, nothing)
        if key === :name && value isa Union{String, Symbol}
            name = String(value)
        elseif key === :urls && Meta.isexpr(value, :vect) && all(string_pair, value.args)
            urls = Pair{String, String}[pair.args[2] => pair.args[3] for pair in value.args]
        else
            throw(ArgumentError("invalid `@startup` option `$option`"))
        end
    end
    deps = dependencies!(String[], body)
    return :($load($name, $(String(__source__.file::Symbol)), $urls, $deps))
end

"""
    dependencies!(deps::Vector{String}, ex)::Vector{String}

Append the root of every `using` and `import` path in `ex` to `deps` unless already there.

Quoted expressions count, while relative paths and `Base`, `Core` and `Main` do not.

# Examples
```jldoctest
julia> dependencies!(String[], :(using Revise: includet; import .Local, Base.Iterators, Revise)),
       dependencies!(["Revise"], :(register([:(using Statistics: mean)])))
(["Revise"], ["Revise", "Statistics"])
```
"""
function dependencies!(deps::Vector{String}, @nospecialize(ex))
    ex isa Expr || return deps
    if ex.head === :using || ex.head === :import
        for path in ex.args
            Meta.isexpr(path, :(:)) && (path = path.args[1])
            Meta.isexpr(path, :as) && (path = path.args[1])
            root = path.args[1]
            root isa Symbol && root ∉ (:., :Base, :Core, :Main) && String(root) ∉ deps && push!(deps, String(root))
        end
    end
    for arg in ex.args
        dependencies!(deps, arg)
    end
    return deps
end

include("session.jl")
include("generation.jl")

precompile(var"@startup", (LineNumberNode, Module, Expr))
precompile(var"@startup", (LineNumberNode, Module, Expr, Expr))
precompile(var"@startup", (LineNumberNode, Module, Expr, Expr, Expr))
precompile(load, (String, String, Vector{Pair{String, String}}, Vector{String}))
precompile(activate, (String, Bool))
precompile(wait_for_repl, ())
precompile(precompile_quietly, (Base.PkgId, IOBuffer))
precompile(track, ())
precompile(run_repl_hooks, (Any, Int, IOBuffer))
precompile(wait_for_loading, (Any,))
precompile(guard_imports, (Any,))
precompile(atreplinit, (typeof(guard_imports),))
precompile(statement!, (State, Module, LineNumberNode, Expr))
precompile(link_to_main, (Module, Vector{Symbol}))

end
