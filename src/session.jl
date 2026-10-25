# Code that runs when a session starts: checking the generated package and loading it.

"""
    load(name::String, file::String, urls::Vector{Pair{String, String}}, deps::Vector{String},
        background::Bool = isinteractive())

Load the package `name` generated from the `@startup` call in `file` with [`activate`](@ref), in a task stored in
[`LOADING`](@ref) if `background`, registering [`guard_imports`](@ref) with `atreplinit` then.

When the path, the modification time or the size of `file` differ from the last check by the running Julia minor
version, the stub of the package is written and the missing `deps` are installed with [`install`](@ref), and in the
background, a note tells that the package is precompiled. The check is per minor version, because each minor version
has its own default environment `@v#.#`, into which the dependencies are installed. Throw an `ArgumentError` if
`file` is no file, as for a `@startup` call in the REPL.
"""
function load(name::String, file::String, urls::Vector{Pair{String, String}}, deps::Vector{String},
        background::Bool = isinteractive())
    config = joinpath(first(DEPOT_PATH), "config")
    checked = joinpath(config, name, "checked-v$(VERSION.major).$(VERSION.minor)")
    status = stat(file)
    isfile(status) || throw(ArgumentError("`@startup` must be called in a file, not in `$file`"))
    source = "$file $(status.mtime) $(status.size)"
    changed = !isfile(checked) || read(checked, String) != source
    if changed
        absent = filter(dep -> isnothing(Base.identify_package(dep)), deps)
        isempty(absent) || Base.invokelatest(install, Base.require(PKG), absent, urls)
        stub = joinpath(config, name, "src", name * ".jl")
        code = """
            module $name
            import StartupPackage
            Base.include(StartupPackage.extract, @__MODULE__, $(repr(file)))
            end
            """
        isfile(stub) && read(stub, String) == code || write_atomically(stub, code)
        write_atomically(checked, source)
    end
    # Appended, so that `using` of a package with the same name in an environment still loads that package.
    config in LOAD_PATH || push!(LOAD_PATH, config)
    if background
        changed && println(stderr, "`$name` is precompiled in the background.")
        atreplinit(guard_imports)
        LOADING[] = Threads.@spawn :default activate(name, true)
    else
        activate(name, false)
    end
    return nothing
end

"""
    install(Pkg::Module, names::Vector{String}, urls::Vector{Pair{String, String}})

Add the packages `names` to the default environment in one `Pkg.add` call, from their URL in `urls` if they have one.

`Pkg` is the loaded `Pkg` module. Call this function with `Base.invokelatest` after loading `Pkg`.
"""
function install(Pkg::Module, names::Vector{String}, urls::Vector{Pair{String, String}})
    url = Dict(urls)
    specs = [Pkg.PackageSpec(; name, url = get(url, name, nothing)) for name in names]
    Pkg.activate(() -> Pkg.add(specs), Base.load_path_expand("@v#.#"))
    return nothing
end

"""
    write_atomically(path::String, content::String)

Write `content` to `path` through a temporary file and a rename, creating the directory if needed.

Another process reads either the old or the new content of `path`, never a partial one.

# Examples
```jldoctest
julia> mktempdir() do dir
           path = joinpath(dir, "src", "A.jl")
           write_atomically(path, "module A end")
           first = read(path, String)
           write_atomically(path, "module B end")
           first, read(path, String), readdir(dirname(path))
       end
("module A end", "module B end", ["A.jl"])
```
"""
function write_atomically(path::String, content::String)
    mkpath(dirname(path))
    temp = tempname(dirname(path); cleanup = false)
    write(temp, content)
    Base.Filesystem.rename(temp, path)
    return nothing
end

"""
    activate(name::String, background::Bool)

Load the generated package `name`, bind it to a constant of the same name in `Main`, run `using` of it there, and
offer the loaded packages to Revise with [`track`](@ref).

If `background`, first wait for the REPL with [`wait_for_repl`](@ref) and precompile the package with
[`precompile_quietly`](@ref). After loading, run the hooks that loading registered with [`run_repl_hooks`](@ref).
Errors, together with the output of precompilation, are not thrown, but shown with [`report`](@ref).
"""
function activate(name::String, background::Bool)
    id = Base.PkgId(nothing, name)
    output = IOBuffer()
    hooks = 0
    try
        if background
            wait_for_repl()
            hooks = length(Base.repl_hooks)
            Base.isprecompiled(id) || (precompile_quietly(id, output); take!(output))
        end
        mod = Base.require(id)
        # The builtin of Julia 1.13 saves lowering a `const`, about 0.6 ms.
        @static if isdefined(Core, :declare_const)
            Core.declare_const(Main, Symbol(name), mod)
        else
            Core.eval(Main, Expr(:const, Expr(:(=), Symbol(name), mod)))
        end
        Core.eval(Main, Expr(:using, Expr(:., :., Symbol(name))))
        Base.invokelatest(track)
        if background && isdefined(Base, :active_repl)
            # Not `output`, which `Base.compilecache` leaves unwritable on Julia 1.10.
            errors = IOBuffer()
            run_repl_hooks(Base.active_repl, length(Base.repl_hooks) - hooks, errors)
            errors.size > 0 && report("A REPL hook of `$name` failed: " * String(take!(errors)))
        end
    catch err
        # Any error, as nothing else would show it.
        background || rethrow()
        report(String(take!(output)) * "Loading `$name` failed: " * sprint(showerror, err, catch_backtrace()))
    end
    return nothing
end

"""
    wait_for_repl(limit::Float64 = 600.0)

Wait until the REPL of an interactive session shows its prompt, so that loading does not delay it, but at most `limit`
seconds, as an interactive session may have no REPL.

The backend exists only after Julia ran the hooks registered with `atreplinit`, so hooks that loading registers
cannot disturb that pass. Check every 10 ms, after the first second every 1 % of the time waited, so that waiting
delays loading by at most 1 %. Return at once in a session that is not interactive.
"""
function wait_for_repl(limit::Float64 = 600.0)
    isinteractive() || return nothing
    start = time()
    # A `LineEditREPL` shows its prompt once its `interface` exists.
    while !isdefined(Base, :active_repl_backend) || isnothing(Base.active_repl_backend) ||
            !isdefined(Base, :active_repl) ||
            hasfield(typeof(Base.active_repl), :interface) && !isdefined(Base.active_repl, :interface)
        waited = time() - start
        waited < limit || break
        sleep(max(0.01, waited / 100))
    end
    return nothing
end

"""
    precompile_quietly(id::Base.PkgId, io::IO)

Precompile the package `id` and its dependencies, writing all output to `io`.

The dependencies are precompiled in parallel from Julia 1.12 on.
"""
function precompile_quietly(id::Base.PkgId, io::IO)
    # Julia 1.11 finds no package without a `Project.toml` there.
    @static if VERSION >= v"1.12"
        Base.Precompilation.precompilepkgs([id]; io, _from_loading = true)
    else
        Base.compilecache(id, Base.locate_package(id)::String, io, io)
    end
    return nothing
end

"""
    track()

Offer each loaded package outside of the system image to Revise, if Revise is loaded.

Revise tracks the packages that are loaded after it. Without this, the packages loaded before it, its own
dependencies among them, are not tracked, unlike with Revise loaded by a plain `startup.jl`. Revise skips the
packages it already tracks.
"""
function track()
    revise = get(Base.loaded_modules, REVISE, nothing)
    (isnothing(revise) || !isdefined(revise, :watch_package_callback)) && return nothing
    callback = getglobal(revise, :watch_package_callback)
    for id in Base.@lock Base.require_lock collect(keys(Base.loaded_modules))
        Base.in_sysimage(id) || callback(id)
    end
    return nothing
end

"""
    run_repl_hooks(repl, count::Int, io::IO)

Run the `count` hooks registered last with `atreplinit` with `repl`, in the order in which Julia runs hooks, and
write the error of a failing hook to `io` instead of stopping.

Julia runs the hooks once, before the REPL starts. This runs those that the generated package and its dependencies
register when they are loaded later, in the background.

# Examples
```jldoctest
julia> calls = String[];

julia> atreplinit(repl -> push!(calls, repl)); atreplinit(repl -> error("broken"));

julia> io = IOBuffer(); run_repl_hooks("repl", 2, io); deleteat!(Base.repl_hooks, 1:2);

julia> calls, String(take!(io))
(["repl"], "broken\\n")
```
"""
function run_repl_hooks(@nospecialize(repl), count::Int, io::IO)
    for hook in Base.repl_hooks[1:count]
        try
            Base.invokelatest(hook, repl)
        catch err
            # Any error, as Julia's own hook runner does.
            showerror(io, err)
            println(io)
        end
    end
    return nothing
end

"""
    report(message::String)

Print `message` to `stderr` when the REPL evaluates the next input, or at once without a REPL.

# Examples
```jldoctest
julia> report("Loading `Startup` failed.")
Loading `Startup` failed.
```
"""
function report(message::String)
    backend = isdefined(Base, :active_repl_backend) ? Base.active_repl_backend : nothing
    if isnothing(backend)
        println(stderr, message)
    else
        pending = Ref(true)
        push!(backend.ast_transforms, function (ex)
            pending[] && (pending[] = false; println(stderr, message))
            return ex
        end)
    end
    return nothing
end

"""
    guard_imports(repl)

Add [`wait_for_loading`](@ref) to the transforms of the REPL input that the backends of `repl` start with.

Registered with `atreplinit`, this runs before the backend of `repl` starts, so before any input is evaluated.

# Examples
```jldoctest
julia> module FakeREPL; const repl_ast_transforms = Any[]; struct R end; end;

julia> guard_imports(FakeREPL.R()); FakeREPL.repl_ast_transforms == [wait_for_loading]
true
```
"""
function guard_imports(@nospecialize(repl))
    pushfirst!(getglobal(parentmodule(typeof(repl)), :repl_ast_transforms), wait_for_loading)
    return nothing
end

"""
    wait_for_loading(ex)

Return the REPL input `ex`, after waiting for [`LOADING`](@ref) if `ex` contains `using` or `import`.

This lets a package that the REPL loads load after the generated package. The loading lock does not ensure this, as
Julia releases it while a package runs its `__init__`.

# Examples
```jldoctest
julia> ready = Channel{Nothing}(1); LOADING[] = Threads.@spawn take!(ready);

julia> wait_for_loading(:(1 + 1))
:(1 + 1)

julia> waiting = Threads.@spawn wait_for_loading(:(using Printf)); sleep(0.1); istaskdone(waiting)
false

julia> put!(ready, nothing); fetch(waiting)
:(using Printf)

julia> LOADING[] = nothing;
```
"""
function wait_for_loading(@nospecialize(ex))
    task = LOADING[]
    isnothing(task) || istaskdone(task) || !imports(ex) || wait(task)
    return ex
end

"""
    link_to_main(mod::Module, names::Vector{Symbol})

Make `names` in `mod` resolve to the globals of the same names in `Main`, once `Main` defines them.

`Main` exports `names`, and `mod` loads `Main` with `using`. This must run after precompilation, which forbids
`using Main`. A name that `mod` defines itself is not affected.

# Examples
```jldoctest
julia> module L
           twice(x) = helper(2x)
       end;

julia> link_to_main(L, [:helper])

julia> L.twice(1)
ERROR: UndefVarError: `helper` not defined in `L`
[...]

julia> Core.eval(Main, :(helper(x) = x + 1));

julia> L.twice(1)
3
```
"""
function link_to_main(mod::Module, names::Vector{Symbol})
    isempty(names) && return nothing
    Core.eval(Main, Expr(:export, names...))
    Core.eval(mod, Expr(:using, Expr(:., :Core, :Main)))
    return nothing
end
