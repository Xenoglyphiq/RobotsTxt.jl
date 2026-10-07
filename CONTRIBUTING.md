# Contributing to robots.txt for Julia

Thanks for helping. This package is one of several language ports of the same spec, and all of them must behave identically.

## How this repo works

- The package itself lives at the repo root, laid out the way Julia expects: `Project.toml` and `src/RobotsTxt.jl` (the core), with the io layer (`fetch` and its transport) in `src/fetch.jl`. Tests, the conformance runner and the fuzz harness are in `test/`; the benchmark harness is in `bench/`.
- **`.spec/`** is a copy of the spec and its conformance cases from **`Xenoglyphiq/robotstxt-spec`**, at the version in `.spec/SPEC_VERSION`. Don't edit it here; it's replaced when the port moves to a newer spec.
- **`.kit/`** holds shared conventions, schemas and the validator. Don't edit it here either.

Read `.kit/CONVENTIONS.md` and `.spec/spec/SPEC.md` before changing behavior.

## Where to send a change

| You want to… | Where |
|---|---|
| Fix a bug in this port | Here. Add a test or point to the conformance case it fixes |
| Change how the library behaves | The spec repo `Xenoglyphiq/robotstxt-spec`. Open an issue there first |
| Report that this port behaves differently from another | The spec repo, with the input; it becomes a conformance case |
| Improve docs or examples for this port | Here |

## Checks every PR must pass

1. `uv run .kit/validate.py .spec` (or `python .kit/validate.py .spec` after `pip install pyyaml jsonschema`)
2. Build and unit tests: `julia --project -e 'using Pkg; Pkg.test()'` on Julia 1.10 (LTS) and current
3. Conformance runner: part of `Pkg.test()` (`test/conformance.jl`); every claimed level must pass
4. The three canonical examples: `julia --project examples/<name>.jl` for each

## Style

- Follow Julia's own conventions for names, errors and packaging.
- Errors keep the kinds and codes from the spec; tests assert kind and code, never message text.
- Every public item has a doc comment naming the spec operation it implements.
- The core does no I/O. Anything that touches the network belongs in `src/fetch.jl`, and format logic stays out of it.

## License

By contributing you agree your contribution is licensed under MIT OR Apache-2.0, the same as this project.
