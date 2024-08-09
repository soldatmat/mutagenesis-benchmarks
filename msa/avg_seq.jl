using CSV
using DataFrames
using StatsBase
using Random
using Distances
using Combinatorics

Random.seed!(42)

# ___ Helper functions ___
normalize_score(score::Real) = (score - minimum(df.score)) / (maximum(df.score) - minimum(df.score))
denormalize_score(score::Real) = score * (maximum(df.score) - minimum(df.score)) + minimum(df.score)

function get_percentile(df::DataFrame, percentile::Tuple{T,T}) where {T<:Real}
    df_sorted = sort(df, :score)
    n_sequences = size(df_sorted)[1]
    df_sorted = df_sorted[Int(floor(n_sequences * percentile[1]) + 1):Int(floor(n_sequences * percentile[2])), :]
end

function get_mutational_gaps(df::DataFrame)
    df_optimal = get_percentile(df, (0.99, 1.0))
    gaps = pairwise(hamming, df.sequence, df_optimal.sequence)
    map(row -> minimum(row), eachrow(gaps))
end

get_avg_sequence(dists::Vector{Vector{Pair{Char,Int}}}) = map(position -> position[1][1], dists)

function get_mutation_distributions(df::DataFrame)
    dists = map(i -> map(seq -> seq[i], df.sequence), 1:length(df[1, :].sequence))
    map(position -> sort(collect(countmap(position)), by=x -> x[2], rev=true), dists)
end

# ___ Trainin data construction methods ___
# Following https://arxiv.org/pdf/2307.00494
function difficulty_filter(df::DataFrame; percentile_range::Tuple{T,T}, min_gap::Int) where {T<:Real}
    df_sorted = get_percentile(df, percentile_range)
    filter(row -> row.gap >= min_gap, df_sorted)
end
difficulty_filter_medium(df::DataFrame) = difficulty_filter(df; percentile_range=(0.2, 0.4), min_gap=6)
difficulty_filter_hard(df::DataFrame) = difficulty_filter(df; percentile_range=(0.0, 0.3), min_gap=7)

"""
Following https://arxiv.org/pdf/2405.18986

# Keywords
- `n_train::Int`: n_train highest score variants from the percentile
- `n_oracle_calls::Int`: n_oracle_calls random variants from the percentile
"""
function difficulty_filter_alt(df::DataFrame; percentile_range::Tuple{T,T}, n_train::Int, n_oracle_calls::Int) where {T<:Real}
    df_sorted = get_percentile(df, percentile_range)
    df_train = df_sorted[size(df_sorted)[1]-n_train+1:size(df_sorted)[1], :]
    df_oracle_calls = df_sorted[1:size(df_sorted)[1]-n_train, :]
    df_oracle_calls = df_oracle_calls[shuffle(1:nrow(df_oracle_calls))[1:n_oracle_calls], :]
    vcat(df_train, df_oracle_calls)
end
difficulty_filter_alt_medium(df::DataFrame) = difficulty_filter_alt(df; percentile_range=(0.2, 0.4), n_train=128, n_oracle_calls=256)
difficulty_filter_alt_hard(df::DataFrame) = difficulty_filter_alt(df; percentile_range=(0.1, 0.3), n_train=128, n_oracle_calls=256)

# ___ Mutant selection methods ___
function mutate_at_each_position(df::DataFrame; n_mutants::Int)
    dists = get_mutation_distributions(df)
    avg_sequence = get_avg_sequence(dists)
    mutants = map(pos -> copy(avg_sequence), eachindex(dists))
    map(pos -> mutants[pos][pos] = dists[pos][length(dists[pos]) > 1 ? 2 : 1][1], eachindex(dists))
    sample(mutants, n_mutants, replace=false)
end

function common_single_mutants(df::DataFrame; n_mutants::Int)
    dists = get_mutation_distributions(df)
    avg_sequence = get_avg_sequence(dists)
    dist = reduce(vcat, map(pos -> map(pair -> (pair[1], pair[2] == maximum(map(symbol -> symbol[2], dists[pos])) ? -1 : pair[2], pos), dists[pos]), eachindex(dists)))
    sort!(dist, by=x -> x[2], rev=true)
    mutants = map(pos -> copy(avg_sequence), 1:n_mutants)
    map(m -> mutants[m][dist[m][3]] = dist[m][1], eachindex(mutants))
    return mutants
end

function common_double_mutants(df::DataFrame; n_mutants::Int)
    dists = get_mutation_distributions(df)
    avg_sequence = get_avg_sequence(dists)
    dist = reduce(vcat, map(pos -> map(pair -> (pair[1], pair[2] == maximum(map(symbol -> symbol[2], dists[pos])) ? -1 : pair[2], pos), dists[pos]), eachindex(dists)))
    sort!(dist, by=x -> x[2], rev=true)
    mutation_pairs = collect(combinations(dist, 2))
    mutation_pairs = mutation_pairs[map(pair -> pair[1][3] != pair[2][3], mutation_pairs)]
    mutants = map(pos -> copy(avg_sequence), 1:n_mutants)
    map(m -> map(i -> mutants[m][mutation_pairs[m][i][3]] = mutation_pairs[m][i][1], 1:2), eachindex(mutants))
    return mutants
end

# ___ Load dataset ___
dataset_name = "GFP" # Choose from: "GFP", "AAV"
file_path = joinpath(@__DIR__, "..", "data", dataset_name, "ground_truth.csv")
df = CSV.read(file_path, DataFrame)
df.gap = get_mutational_gaps(df)

# ___ Define "training data" - Choose one ___
# (1) Following https://arxiv.org/pdf/2307.00494
df_train = difficulty_filter_medium(df)
df_train = difficulty_filter_hard(df)

# (2) Following https://arxiv.org/pdf/2405.18986
df_train = difficulty_filter_alt_medium(df)
df_train = difficulty_filter_alt_hard(df)

# ___ Create Mutants - Choose one ___
# (A) Most common mutation at each position (! positions with no mutations produce avg_sequence)
mutants = mutate_at_each_position(df_train; n_mutants=128)

# (B) Most common single mutations
mutants = common_single_mutants(df_train; n_mutants=128)

# (C) Double mutants from pairs of most common mutations
mutants = common_double_mutants(df_train; n_mutants=128)

# ___ Prepare Evaluation ___
mutant_strings = map(i -> String(mutants[i]), eachindex(mutants))
default_score = 0
scores = map(mutant -> filter(row -> row.sequence == mutant, df).score, mutant_strings)
mapreduce(s -> length(s) == 0, +, scores) # How many score will be replaced with default_score?
scores = map(s -> length(s) == 0 ? default_score : mean(s), scores)

# ___ Evaluate ___
median(scores)
median(scores) |> normalize_score
median(pairwise(hamming, mutants))
mean(pairwise(hamming, mutants))
