# StartupPackage

Load your `startup.jl` as a precompiled package. In an interactive session, it loads in the background, so the REPL
prompt appears about as fast as without a `startup.jl`. After you change `startup.jl`, the package is precompiled
again in the background, and dependencies that are missing are installed.

## Usage

Write your `~/.julia/config/startup.jl` like this, with your statements as the body of `@startup`. Use `urls` for
unregistered packages:

```julia
if isinteractive()
    if Base.identify_package("StartupPackage") === nothing
        import Pkg
        Pkg.add("StartupPackage")
    end
    using StartupPackage
else
    # Expands `@startup` to nothing, without loading StartupPackage.
    macro startup(args...) end
end

@startup urls = ["UseAll" => "https://github.com/PatrickHaecker/UseAll.jl"] begin
    using Revise, UseAll
    atreplinit() do repl
        repl.options.auto_insert_closing_bracket = false
    end
end
```

`?@startup` in the REPL describes the options and how the package is generated.

## Limitations

The body of `@startup` runs as in a plain `startup.jl`, except that
- in an interactive session, the package is loaded only after the prompt appears. Until it is loaded, the names of
  the body and of the packages it loads are missing, and a `using` or `import` entered in the REPL waits. The
  `atreplinit` hooks of the body and of these packages run as soon as the package is loaded. Their settings apply
  from then on, except those that the REPL reads only when it starts, such as `REPL.repl_ast_transforms`,
- a statement at top level runs only when the package is precompiled, not in each session, so its effects besides
  the cached definitions, such as output or changes to `ENV`, happen only then,
- a condition that guards statements of both kinds runs when the package is precompiled and again in each session,
  so it must not depend on the session,
- a statement at top level cannot use a global that is assigned in the session, which throws an `ErrorException`,
- the type declaration of a global in an expression under a condition, like `ready ? (x::Int = 1) : 0`, holds even
  if the condition is false, and
- before Julia 1.12, the parts of a macro expansion into a `:toplevel` expression cannot use the macros that the
  parts before them import, as the whole expansion happens at once.

Statements at top level are those that define something, call `precompile` or declare the type of a global in a
scope. All others run each time the package is loaded.

## License

MIT, see [LICENSE](LICENSE).
