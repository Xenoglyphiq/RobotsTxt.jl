# Benchmark per `.spec/bench/README.md`: read robots.txt and paths.txt once;
# one pass = for each block of consecutive lines with the same crawler, parse
# the file, then is_allowed for each of the block's paths, summing the 1-based
# line numbers of the allowed ones (must equal the checksum). 3 warm-up passes,
# then 15 timed passes; report median and min.
# Run: julia --project bench/bench.jl [dir]   (default .spec/bench)
# No dependencies; warm-up passes also absorb compilation.

using RobotsTxt

const WARMUP = 3
const RUNS = 15
const CHECKSUM = 24281055

# Blocks of (user_agent, [(line number, path)]) in file order.
function read_blocks(path)
    blocks = Tuple{String,Vector{Tuple{Int,String}}}[]
    for (n, line) in enumerate(eachline(path))
        isempty(line) && continue
        ua, p = split(line, ' '; limit=2)
        if isempty(blocks) || blocks[end][1] != ua
            push!(blocks, (String(ua), Tuple{Int,String}[]))
        end
        push!(blocks[end][2], (n, String(p)))
    end
    return blocks
end

function pass(data::Vector{UInt8}, blocks)::Int
    sum = 0
    for (ua, lookups) in blocks
        robots = RobotsTxt.parse(data)
        for (n, p) in lookups
            RobotsTxt.is_allowed(robots, ua, p) && (sum += n)
        end
    end
    return sum
end

function main(dir=joinpath(@__DIR__, "..", ".spec", "bench"))
    data = read(joinpath(dir, "robots.txt"))
    blocks = read_blocks(joinpath(dir, "paths.txt"))
    for _ in 1:WARMUP
        s = pass(data, blocks)
        s == CHECKSUM || error("checksum $s, expected $CHECKSUM")
    end
    ms = Float64[]
    for _ in 1:RUNS
        t = time_ns()
        s = pass(data, blocks)
        push!(ms, (time_ns() - t) / 1e6)
        s == CHECKSUM || error("checksum $s, expected $CHECKSUM")
    end
    sort!(ms)
    fmt(x) = string(round(x; digits=3))
    lookups = sum(length(b[2]) for b in blocks)
    println("robotstxt julia $(VERSION) ($(length(data)) bytes, $(length(blocks)) crawlers, $lookups lookups): ",
            "median $(fmt(ms[RUNS ÷ 2 + 1])) ms per pass (min $(fmt(ms[1]))), checksum $CHECKSUM")
end

main(ARGS...)
