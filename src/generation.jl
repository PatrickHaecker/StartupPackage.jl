# Code that runs while the generated package is precompiled: turning the body into package code.

"""
    extract(ex)

Return the body of the `@startup` call in the top-level expression `ex` as package code, or `nothing` if there is none.

This is the `mapexpr` with which the generated package includes the file with the `@startup` call. Each statement of
the body goes to [`statement!`](@ref), except that an `atreplinit() do repl ... end` block becomes a named function,
precompiled for a `REPL.LineEditREPL` and registered with `atreplinit`.

# Examples
```jldoctest
julia> extract(:(using StartupPackage)) === nothing
true

julia> ex = extract(quote
           if isinteractive()
               @startup begin
                   using Revise: includet
                   ENV["JULIA_EDITOR"] = "code"
               end
           end
       end);

julia> Tuple(arg.args[end].value for arg in ex.args[2:3])
(:(using Revise: includet), :(ENV["JULIA_EDITOR"] = "code"))

julia> ex.args[end]
:((finish!)(var"#state", @__MODULE__()))
```
"""
function extract(@nospecialize(ex))
    call = find_startup(ex)
    isnothing(call) && return nothing
    current_module = Expr(:macrocall, Symbol("@__MODULE__"), nothing)
    run(f, line, statement) = :($f(var"#state", $current_module, $(QuoteNode(line)), $(QuoteNode(statement))))
    toplevel = Any[:(const var"#state" = $State($current_module))]
    hooks = 0
    line = call.args[2]
    for statement in (last(call.args)::Expr).args
        if statement isa LineNumberNode
            line = statement
        elseif Meta.isexpr(statement, :do, 2) && statement.args[1] == :(atreplinit())
            hooks == 0 && push!(toplevel, run(define!, line, :(import REPL as var"#REPL")))
            hooks += 1
            hook = Symbol("#atreplinit#", hooks)
            arguments, body = statement.args[2].args
            push!(toplevel, run(define!, line, Expr(:function, Expr(:call, hook, arguments.args...), body)),
                :($precompile($hook, (var"#REPL".LineEditREPL,))), run(statement!, line, :($atreplinit($hook))))
        else
            push!(toplevel, run(statement!, line, statement))
        end
    end
    return Expr(:toplevel, toplevel...,
        :($define_init!(var"#state", $current_module, $(QuoteNode(call.args[2])))),
        :($precompile(__init__, ())),
        :($finish!(var"#state", $current_module)))
end

"""
    find_startup(ex)::Union{Nothing, Expr}

Return the first `@startup` or `StartupPackage.@startup` call in `ex` outside of quoted expressions, or `nothing` if
there is none.

# Examples
```jldoctest
julia> find_startup(:(if isinteractive(); StartupPackage.@startup begin end; end)).args[1]
:(StartupPackage.var"@startup")

julia> find_startup(:(const example = :(@startup begin end))) === nothing
true
```
"""
function find_startup(@nospecialize(ex))
    ex isa Expr && ex.head !== :quote || return nothing
    Meta.isexpr(ex, :macrocall) && ex.args[1] in (Symbol("@startup"), :(StartupPackage.var"@startup")) && return ex
    for arg in ex.args
        call = find_startup(arg)
        isnothing(call) || return call
    end
    return nothing
end

"""
    State(mod::Module)

Create the state that the generated package `mod` collects while it is precompiled.

The fields are the names that `mod` has before the body runs (`preexisting`), the globals that the definitions use
(`main_names`), the statements for `__init__` (`initializers`), the globals they assign (`assigned`), the names that
`using` and `import` bring in (`imported`) and the modules loaded with `using M` (`modules`).

# Examples
```jldoctest
julia> module Fresh end;

julia> state = State(Fresh);

julia> :eval in state.preexisting, :twice in state.preexisting
(true, false)
```
"""
struct State
    preexisting::Vector{Symbol}
    main_names::Vector{Symbol}
    initializers::Vector{Any}
    assigned::Vector{Symbol}
    imported::Vector{Symbol}
    modules::Vector{Symbol}
end

State(mod::Module) = State(names(mod; all = true, imported = true), Symbol[], Any[], Symbol[], Symbol[], Symbol[])

"""
    statement!(state::State, mod::Module, line::LineNumberNode, ex, initializers = state.initializers)

Evaluate the part of the statement `ex` from `line` that must run at top level in `mod`, and add the rest to the
statements for `__init__` in `initializers`.

[`separate`](@ref) splits the statement, after the statements before it ran, so that their macros are available.
`__init__` declares the globals of `mod` that its part assigns as `global`. A top-level part that uses one of them
throws an `ErrorException`, see the limitations of [`@startup`](@ref).

The parts of a `:toplevel` expression are handled one by one in the same way. For a macro call that expands to one,
as for `@enum`, `separate` returns a call of `statement!` with the expansion as top-level part, and an empty block as
part for `__init__`, which that call fills. From Julia 1.12 on, such a macro call is expanded one level only, as
earlier versions lose hygiene in a one-level expansion.

# Examples
```jldoctest
julia> module S end;

julia> state = State(S);

julia> line = LineNumberNode(1, :none);

julia> statement!(state, S, line, :(Base.@kwdef struct P; a::Int = 1; end))

julia> statement!(state, S, line, :((left, right) = (1, 2)))

julia> S.P().a, state.initializers, state.assigned
(1, Any[:(#= none:1 =#), :((left, right) = (1, 2))], [:left, :right])
```
"""
function statement!(state::State, mod::Module, line::LineNumberNode, @nospecialize(ex),
        initializers::Vector{Any} = state.initializers)
    if Meta.isexpr(ex, :toplevel)
        for part in ex.args
            part isa LineNumberNode ? (line = part) : statement!(state, mod, line, part, initializers)
        end
        return nothing
    end
    toplevel, runtime = separate(state, mod, ex)
    if !isnothing(toplevel)
        try
            define!(state, mod, line, toplevel)
        catch err
            err isa UndefVarError && err.var in state.assigned || rethrow()
            error("`$(err.var)` is needed at $(line.file):$(line.line) when the package is precompiled, but is ",
                "assigned only when a session starts. Make `$(err.var)` a `const`, or use it only inside functions.")
        end
    end
    isnothing(runtime) && return nothing
    assigned!(state.assigned, mod, Meta.lower(mod, Expr(:block, line, runtime)))
    push!(initializers, line, runtime)
    return nothing
end

"""
    separate(state::State, mod::Module, ex, expanded::Bool = false)

Return the part of the statement `ex` that must run at top level in `mod` and the part for `__init__`, each `nothing`
if empty.

These go to top level, everything else to `__init__`:
- `export`, `public`, `module`, docstrings, string literals and `:meta` expressions,
- statements that contain `using` or `import`, like `try using Revise catch end`, each import calling
  [`imported!`](@ref) when it runs, see [`recorded`](@ref),
- statements whose lowered form [`defines`](@ref) something,
- statements that declare the type of a global in a scope, like `let` or a loop, as a function cannot declare types,
- statements that refer to `Base.precompile` outside of functions, quoted expressions and local bindings, and
- the type declarations of typed global assignments, see [`untype!`](@ref).

`begin` blocks and `if`, `&&` and `||` are split statement by statement, each part keeping the conditions. The part
for `__init__` keeps the condition of an `if` even without statements, as the condition may have effects.

Unless `expanded`, the macros in each statement and condition are expanded once, so that neither part expands them
again. Docstrings and `module` stay unexpanded, as they expand when they run at top level. For a macro call that
expands to a `:toplevel` expression, see [`statement!`](@ref).

# Examples
```jldoctest
julia> state = State(Main);

julia> separate(state, Main, :(ready && (value::Int = 3)))
(:(if ready
      global value::Int
  end), :(if ready
      value = 3
  end))

julia> separate(state, Main, :(twice(x) = 2x))[2] === nothing
true
```
"""
function separate(state::State, mod::Module, @nospecialize(ex), expanded::Bool = false)
    if ex isa String || Meta.isexpr(ex, (:export, :public, :module, :meta)) ||
            Meta.isexpr(ex, :macrocall) && ex.args[1] == GlobalRef(Core, Symbol("@doc"))
        return ex, nothing
    elseif Meta.isexpr(ex, :macrocall)
        expansion = VERSION >= v"1.12" ? macroexpand(mod, ex; recursive = false) : macroexpand(mod, ex)
        Meta.isexpr(expansion, :toplevel) || return separate(state, mod, macroexpand(mod, expansion), true)
        line = ex.args[2] isa LineNumberNode ? ex.args[2] : LineNumberNode(0)
        slot = Expr(:block)
        return :($statement!($state, $mod, $(QuoteNode(line)), $(QuoteNode(expansion)), $(QuoteNode(slot.args)))), slot
    elseif Meta.isexpr(ex, (:&&, :||))
        rest = length(ex.args) == 2 ? ex.args[2] : Expr(ex.head, ex.args[2:end]...)
        branches = ex.head === :&& ? (rest,) : (nothing, rest)
        return separate(state, mod, Expr(:if, ex.args[1], branches...), expanded)
    elseif Meta.isexpr(ex, (:block, :if, :elseif))
        conditions = ex.head === :block ? 0 : 1
        args = copy(ex.args)
        declarations = Any[]
        if conditions == 1
            expanded || (args[1] = macroexpand(mod, args[1]))
            args[1] = untype!(declarations, args[1])
        end
        parts = [i <= conditions || arg isa LineNumberNode ? (arg, arg) : separate(state, mod, arg, expanded)
            for (i, arg) in enumerate(args)]
        empty(args) = all(arg -> isnothing(arg) || arg isa LineNumberNode, args[conditions + 1:end])
        # The branches of `if` are positional, so they stay even if `nothing`.
        rebuilt(head, args) = empty(args) ? nothing : Expr(head, (conditions == 0 ? filter(!isnothing, args) : args)...)
        toplevel, runtime = Any[first(part) for part in parts], Any[last(part) for part in parts]
        runtime = conditions == 0 ? rebuilt(ex.head, runtime) : Expr(ex.head, runtime...)
        isempty(declarations) && return rebuilt(ex.head, toplevel), runtime
        # Declared before the condition runs, so an `elseif` becomes an `if` in an `else` branch.
        return preceded(Expr(:global, declarations...), rebuilt(:if, toplevel)), runtime
    end
    expanded || (ex = macroexpand(mod, ex))
    Meta.isexpr(ex, :global) && all(arg -> arg isa Symbol || Meta.isexpr(arg, :(::)), ex.args) && return ex, nothing
    declarations = Any[]
    ex = untype!(declarations, ex)
    declared = isempty(declarations) ? nothing : Expr(:global, declarations...)
    imports(ex) && return preceded(declared, recorded(state, ex)), nothing
    lowered = Meta.lower(mod, ex)
    defines(lowered) && return preceded(declared, ex), nothing
    code = Meta.isexpr(lowered, :thunk) ? (lowered.args[1]::Core.CodeInfo).code : Any[]
    # A type declaration of a global left in a scope, as lowered by Julia 1.10, 1.12 and 1.13, cannot be in a function.
    typed(x) = Meta.isexpr(x, :globaldecl, 2) || Meta.isexpr(x, :call) &&
        (x.args[1] == GlobalRef(Core, :set_binding_type!) ||
            x.args[1] == GlobalRef(Core, :declare_global) && length(x.args) == 5)
    any(typed, code) && return preceded(declared, ex), nothing
    # Locals are slots and function bodies nested `CodeInfo`s, so neither counts. Assigned names are not resolved.
    precompiles(x) = resolved(mod, code, x) === Base.precompile ||
        Meta.isexpr(x, :call) && any(precompiles, x.args) || Meta.isexpr(x, :(=), 2) && precompiles(x.args[2])
    any(precompiles, code) && return preceded(declared, ex), nothing
    return declared, ex
end

"""
    imports(ex)::Bool

Return whether `ex` contains `using` or `import` outside of quoted expressions.

# Examples
```jldoctest
julia> imports(:(try using Revise catch end)), imports(:(register(:(using Statistics))))
(true, false)
```
"""
function imports(@nospecialize(ex))
    ex isa Expr && ex.head !== :quote || return false
    ex.head in (:using, :import) && return true
    # A loop, as `any(imports, ex.args)` compiles in each session, at the first REPL input.
    for arg in ex.args
        imports(arg) && return true
    end
    return false
end

"""
    resolved(mod::Module, code::Vector{Any}, x)

Return the constant global that `x` in the lowered top-level code `code` of `mod` refers to, `nothing` if it is
undefined or not constant, or `x` itself if it is no reference to a global.

`x` is a global name, a `GlobalRef`, an `SSAValue` or a call of `getproperty` on a module, as for `Base.precompile`.
The value of a global that is not constant may change before `x` runs.

# Examples
```jldoctest
julia> code = Any[:Base, Expr(:call, :getproperty, Core.SSAValue(1), QuoteNode(:precompile))];

julia> resolved(Main, code, Core.SSAValue(2)) === precompile
true

julia> module Own; precompile(x) = x; callback = Base.precompile; end;

julia> resolved(Own, Any[], :precompile) === precompile, resolved(Own, Any[], :callback)
(false, nothing)
```
"""
function resolved(mod::Module, code::Vector{Any}, @nospecialize(x))
    if x isa Core.SSAValue
        return resolved(mod, code, code[x.id])
    elseif x isa Symbol || x isa GlobalRef
        owner, name = x isa Symbol ? (mod, x) : (x.mod, x.name)
    elseif Meta.isexpr(x, :call, 3) && x.args[3] isa QuoteNode && resolved(mod, code, x.args[1]) === getproperty
        owner, name = resolved(mod, code, x.args[2]), x.args[3].value
    else
        return x
    end
    return owner isa Module && name isa Symbol && isconst(owner, name) ? getglobal(owner, name) : nothing
end

"""
    recorded(state::State, ex)

Return `ex` with a call of [`imported!`](@ref) after each `using` and `import` statement outside of quoted expressions.

An import in a branch that does not run is not recorded. A statement that loads several modules, like
`using A, B`, becomes one statement per module, so that `A` is recorded even if loading `B` fails.

# Examples
```jldoctest
julia> ex = recorded(State(Main), :(using Base: sin));

julia> ex.head, ex.args[1]
(:block, :(using Base: sin))

julia> quoted = :(example = :(using Base: sin));

julia> recorded(State(Main), quoted) == quoted
true
```
"""
function recorded(state::State, @nospecialize(ex))
    ex isa Expr && ex.head !== :quote || return ex
    if Meta.isexpr(ex, (:using, :import))
        single = Meta.isexpr(ex.args[1], :(:)) ? Any[ex] : Any[Expr(ex.head, path) for path in ex.args]
        return Expr(:block, Iterators.flatten((s, :($imported!($state, $(QuoteNode(s))))) for s in single)...)
    end
    # A comprehension, as Julia 1.10 can miscompile a splatted generator here to an empty `Expr`.
    return Expr(ex.head, Any[recorded(state, arg) for arg in ex.args]...)
end

"""
    imported!(state::State, ex::Expr)

Append the names that the `using` or `import` statement `ex` brought in to `state.imported`, and the modules that it
loaded with `using M` to `state.modules`.

# Examples
```jldoctest
julia> state = State(Module());

julia> imported!(state, :(using TerminalPager: pager, @help));

julia> imported!(state, :(using UseAll, Base.Iterators));

julia> imported!(state, :(import Revise as R));

julia> state.imported, state.modules
([:pager, Symbol("@help"), :UseAll, :Iterators, :R], [:UseAll, :Iterators])
```
"""
function imported!(state::State, ex::Expr)
    if Meta.isexpr(ex.args[1], :(:))
        for item in ex.args[1].args[2:end]
            push!(state.imported, Meta.isexpr(item, :as) ? item.args[2] : last(item.args))
        end
    else
        for path in ex.args
            Meta.isexpr(path, :as) && (push!(state.imported, path.args[2]); continue)
            push!(state.imported, last(path.args))
            ex.head === :using && push!(state.modules, last(path.args))
        end
    end
    return nothing
end

"""
    untype!(declarations::Vector{Any}, ex)

Return `ex` without the types of the globals that its assignments and `global` statements declare, and append these
declarations `x::T` to `declarations`.

Typed elements of a tuple on the left side count, assignments nested in other expressions too. Scopes, like
functions, `let` and loops, as well as `local`, `const` and quoted expressions stay as they are, and so does a type
assertion that is no declaration.

# Examples
```jldoctest
julia> declarations = [];

julia> untype!(declarations, :((left::Int, right::Int) = (1, 2)))
:((left, right) = (1, 2))

julia> untype!(declarations, :(value = (flag::Bool = true)))
:(value = (flag = true))

julia> local_scope = :(let local_value::Int = 1; local_value::Int end);

julia> untype!(declarations, local_scope) === local_scope
true

julia> Tuple(declarations)
(:(left::Int), :(right::Int), :(flag::Bool))
```
"""
function untype!(declarations::Vector{Any}, @nospecialize(ex))
    kept = (:function, :->, :let, :for, :while, :try, :struct, :macro, :module, :do, :comprehension, :generator, :local, :const, :quote)
    ex isa Expr && ex.head ∉ kept || return ex
    if ex.head === :(=)
        target = ex.args[1]
        while Meta.isexpr(target, (:where, :(::)))
            target = target.args[1]
        end
        # A short function definition, like `f(x) = x`, is a scope.
        Meta.isexpr(target, :call) && return ex
        return Expr(:(=), declared!(declarations, ex.args[1]), untype!(declarations, ex.args[2]))
    elseif ex.head === :global
        return Expr(:global, Any[declared!(declarations, untype!(declarations, arg)) for arg in ex.args]...)
    end
    return Expr(ex.head, Any[untype!(declarations, arg) for arg in ex.args]...)
end

"""
    declared!(declarations::Vector{Any}, target)

Return the left side `target` of an assignment or a name in a `global` statement without the types it declares, and
append these declarations `x::T` to `declarations`.

# Examples
```jldoctest
julia> declarations = [];

julia> declared!(declarations, :((left::Int, right)))
:((left, right))

julia> declared!(declarations, :(values[1])), declarations
(:(values[1]), Any[:(left::Int)])
```
"""
function declared!(declarations::Vector{Any}, @nospecialize(target))
    if Meta.isexpr(target, :(::), 2) && target.args[1] isa Symbol
        push!(declarations, target)
        return target.args[1]
    end
    Meta.isexpr(target, :tuple) && return Expr(:tuple, Any[declared!(declarations, arg) for arg in target.args]...)
    return target
end

"""
    preceded(first, second)

Return a block of `first` and `second`, or the one that is not `nothing`.

# Examples
```jldoctest
julia> preceded(:(global x::Int), :answer).head
:block

julia> preceded(nothing, :answer)
:answer
```
"""
preceded(@nospecialize(first), @nospecialize(second)) = isnothing(first) ? second : isnothing(second) ? first : Expr(:block, first, second)

"""
    assigned!(names::Vector{Symbol}, mod::Module, lowered)::Vector{Symbol}

Append the globals of `mod` that the lowered top-level statement `lowered` assigns to `names`, unless already there.

Assignments in method bodies, closures included, do not count, as these are nested `CodeInfo`s.

# Examples
```jldoctest
julia> assigned!(Symbol[], Main, Meta.lower(Main, :((left, right) = (1, 2)))),
       assigned!(Symbol[], Main, Meta.lower(Main, Expr(:(=), GlobalRef(Base, :flag), true)))
([:left, :right], Symbol[])
```
"""
function assigned!(names::Vector{Symbol}, mod::Module, @nospecialize(lowered))
    Meta.isexpr(lowered, :thunk) || return names
    for code in (lowered.args[1]::Core.CodeInfo).code
        # Every assignment of a global, typed or not, starts with looking up the type of the global.
        if Meta.isexpr(code, :call) && code.args[1] == GlobalRef(Core, :get_binding_type) && code.args[2] === mod
            name = code.args[3]
            name isa QuoteNode && (name = name.value)
            name isa Symbol && name ∉ names && push!(names, name)
        end
    end
    return names
end

"""
    define!(state::State, mod::Module, line::LineNumberNode, ex)

Lower the definition `ex` from `line` in `mod`, evaluate the lowered form, and append the globals of `mod` that it
uses to `state.main_names`.

The method bodies in `ex`, closures included, are part of its lowered form. Locals do not count. A `module` is
evaluated as top-level code, without collecting globals.

# Examples
```jldoctest
julia> module E end;

julia> state = State(E);

julia> define!(state, E, LineNumberNode(1, :none), :(twice(x) = helper(2x)));

julia> define!(state, E, LineNumberNode(2, :none), :(shifted(x) = (local offset = 1; x + offset)));

julia> state.main_names, isdefined(E, :shifted)
([:twice, :helper, :*, :shifted, :+], true)
```
"""
function define!(state::State, mod::Module, line::LineNumberNode, @nospecialize(ex))
    if Meta.isexpr(ex, :module)
        Core.eval(mod, Expr(:toplevel, line, ex))
        return nothing
    end
    lowered = Meta.lower(mod, Expr(:block, line, ex))
    globals!(state.main_names, mod, lowered)
    Core.eval(mod, lowered)
    return nothing
end

# Called with the module and the name as first two arguments.
const DEFINERS = Any[GlobalRef(Core, name) for name in (:_structtype, :_abstracttype, :_primitivetype, :declare_const)]

"""
    defines(code)::Bool

Return whether the lowered `code` defines a method, a type or a constant with a name that is not generated.

Closures of a statement get generated names starting with `#`, so a statement that only creates closures defines
nothing.

# Examples
```jldoctest
julia> defines(Meta.lower(Main, :(@inline twice(x) = 2x)))
true

julia> defines(Meta.lower(Main, :(const answer = 42)))
true

julia> defines(Meta.lower(Main, :(foreach(x -> println(x), 1:2))))
false
```
"""
function defines(@nospecialize(code))
    if code isa Expr
        name = code.head in (:method, :const) ? code.args[1] :
            Meta.isexpr(code, :call) && code.args[1] in DEFINERS ? code.args[3] : nothing
        # A method of a qualified function like `Base.show` has `nothing` there, one of a closure `false`.
        code.head === :method && isnothing(code.args[1]) && return true
        name isa GlobalRef && (name = name.name)
        name isa QuoteNode && (name = name.value)
        name isa Symbol && !startswith(String(name), '#') && return true
        return any(defines, code.args)
    elseif code isa Core.CodeInfo
        return any(defines, code.code)
    end
    return false
end

"""
    define_init!(state::State, mod::Module, line::LineNumberNode)

Define `__init__` in `mod` from `line` with the statements collected in `state`.

`__init__` first runs [`link_to_main`](@ref) and declares the assigned names as globals.

# Examples
```jldoctest
julia> module I end;

julia> state = State(I);

julia> statement!(state, I, LineNumberNode(1, :none), :(answer = 42))

julia> define_init!(state, I, LineNumberNode(1, :none))

julia> finish!(state, I)

julia> isdefined(I, :answer), (I.__init__(); I.answer)
(false, 42)
```
"""
function define_init!(state::State, mod::Module, line::LineNumberNode)
    initializers = state.initializers
    isempty(state.assigned) || pushfirst!(initializers, Expr(:global, state.assigned...))
    pushfirst!(initializers, :($link_to_main($mod, $(state.main_names))))
    define!(state, mod, line, Expr(:function, :(__init__()), Expr(:block, initializers...)))
    empty!(initializers)
    return nothing
end

"""
    finish!(state::State, mod::Module)

Keep only the globals in `state.main_names` that `mod` does not define, and export the names that the body defined,
assigned or imported from `mod`, including the exports of the modules loaded with `using M`. Imports in branches
that did not run are not exported.

# Examples
```jldoctest
julia> module F end;

julia> state = State(F);

julia> statement!(state, F, LineNumberNode(1, :none), :(using Base: summarysize))

julia> statement!(state, F, LineNumberNode(2, :none), :(twice(x) = helper(2x)))

julia> finish!(state, F)

julia> state.main_names, Base.isexported.(Ref(F), (:summarysize, :twice, :eval))
([:helper], (true, true, false))
```
"""
function finish!(state::State, mod::Module)
    filter!(name -> !isdefined(mod, name) && name ∉ state.assigned, state.main_names)
    exported = filter(names(mod; all = true)) do name
        name ∉ state.preexisting && name !== :__init__ && !startswith(String(name), '#')
    end
    append!(exported, state.assigned, state.imported)
    for name in state.modules
        m = getglobal(mod, name)::Module
        append!(exported, Iterators.filter(n -> Base.isexported(m, n), names(m)))
    end
    Core.eval(mod, Expr(:export, exported...))
    return nothing
end

"""
    globals!(names::Vector{Symbol}, mod::Module, code)::Vector{Symbol}

Append the names of the globals of `mod` that the lowered `code` uses, nested `CodeInfo`s included, to `names`.

Lowered code holds a global as a `GlobalRef` (Julia 1.12 and later) or as a bare `Symbol` (earlier versions), while
locals are slots. `Symbol`s in `:meta` expressions and in `using` and `import` paths are no globals. Names already in
`names` are skipped.

# Examples
```jldoctest
julia> code = Meta.lower(Main, :(f() = (g(); Base.h())));

julia> globals!(Symbol[], Main, code),
       globals!([:g], Main, Any[GlobalRef(Main, :g), :h, Expr(:meta, :inline)])
([:f, :g, :Base], [:g, :h])
```
"""
function globals!(names::Vector{Symbol}, mod::Module, @nospecialize(code))
    if code isa GlobalRef || code isa Symbol
        name = code isa Symbol ? code : code.mod === mod ? code.name : nothing
        isnothing(name) || name ∈ names || push!(names, name)
    elseif code isa Expr
        code.head in (:meta, :using, :import) && return names
        foreach(arg -> globals!(names, mod, arg), code.args)
    elseif code isa Core.CodeInfo || code isa Vector{Any}
        foreach(arg -> globals!(names, mod, arg), code isa Core.CodeInfo ? code.code : code)
    elseif code isa Core.ReturnNode
        isdefined(code, :val) && globals!(names, mod, code.val)
    elseif code isa Core.GotoIfNot
        globals!(names, mod, code.cond)
    end
    return names
end
