
@enum IndexType::UInt8 NotAnIndex=0 LoopIndex=1 ComputedIndex=2 SymbolicIndex=3

Base.:|(u::Unsigned, it::IndexType) = u | UInt8(it)
Base.:(==)(u::Unsigned, it::IndexType) = (u % UInt8) == UInt8(it)

"""
    ArrayRefStruct

A condensed representation of an [`ArrayReference`](@ref).
It supports array-references with up to 8 indexes, where the data for each consecutive index is packed into corresponding 8-bit fields
of `index_types` (storing the enum `IndexType`), `indices` (the `id` for each index symbol), and `offsets` (currently unused).
"""
struct ArrayRefStruct{array,ptr}
    index_types::UInt64
    indices::UInt64
    offsets::UInt64
end
array(ar::ArrayRefStruct{a,p}) where {a,p} = a
ptr(ar::ArrayRefStruct{a,p}) where {a,p}   = p

function findindoradd!(v::Vector{T}, s::T) where {T}
    ind = findfirst(sᵢ -> sᵢ == s, v)
    ind === nothing || return ind
    push!(v, s)
    length(v)
end
function ArrayRefStruct(ls::LoopSet, mref::ArrayReferenceMeta, arraysymbolinds::Vector{Symbol}, ids::Vector{Int})
    index_types = zero(UInt64)
    indices = zero(UInt64)
    offsets = zero(UInt64)
    indv = mref.ref.indices
    offv = mref.ref.offsets
    # we can discard that the array was considered discontiguous, as it should be recovered from type information
    start = 1 + (first(indv) === Symbol("##DISCONTIGUOUSSUBARRAY##"))
    for (n,ind) ∈ enumerate(@view(indv[start:end]))
        index_types <<= 8
        indices <<= 8
        offsets <<= 8
        offsets |= (offv[n] % UInt8)
        if mref.loopedindex[n]
            index_types |= LoopIndex
            indices |= getloopid(ls, ind)
        else
            parent = get(ls.opdict, ind, nothing)
            @assert !isnothing(parent) "Index $ind not found in array."
            # if parent === nothing
            #     index_types |= SymbolicIndex
            #     indices |= findindoradd!(arraysymbolinds, ind)
            # else
            index_types |= ComputedIndex
            indices |= ids[identifier(parent)]
            # end
        end
    end
    ArrayRefStruct{mref.ref.array,mref.ptr}( index_types, indices, offsets )
end

"""
    OperationStruct

A condensed representation of an [`Operation`](@ref).
"""
struct OperationStruct <: AbstractLoopOperation
    # instruction::Instruction
    loopdeps::UInt64
    reduceddeps::UInt64
    childdeps::UInt64
    parents::UInt64
    node_type::OperationType
    array::UInt8
    symid::UInt8
end
optype(os) = os.node_type

function findmatchingarray(ls::LoopSet, mref::ArrayReferenceMeta)
    id = 0x01
    for r ∈ ls.refs_aliasing_syms
        r == mref && return id
        id += 0x01
    end
    0x00
end
# filled_4byte_chunks(u::UInt64) = 16 - (leading_zeros(u) >>> 2)
filled_8byte_chunks(u::UInt64) = 8 - (leading_zeros(u) >>> 3)

# num_loop_deps(os::OperationStruct) = filled_4byte_chunks(os.loopdeps)
# num_reduced_deps(os::OperationStruct) = filled_4byte_chunks(os.reduceddeps)
# num_child_deps(os::OperationStruct) = filled_4byte_chunks(os.childdeps)
# num_parents(os::OperationStruct) = filled_4byte_chunks(os.parents)

function shifted_loopset(ls::LoopSet, loopsyms::Vector{Symbol})
    ld = zero(UInt64) # leading_zeros(ld) >> 2 yields the number of loopdeps
    for d ∈ loopsyms
        ld <<= 4
        ld |= getloopid(ls, d)::Int
    end
    ld
end
loopdeps_uint(ls::LoopSet, op::Operation) = shifted_loopset(ls, loopdependencies(op))
reduceddeps_uint(ls::LoopSet, op::Operation) = shifted_loopset(ls, reduceddependencies(op))
childdeps_uint(ls::LoopSet, op::Operation) = shifted_loopset(ls, reducedchildren(op))
function parents_uint(ls::LoopSet, op::Operation)
    p = zero(UInt64)
    for parent ∈ parents(op)
        p <<= 8
        p |= identifier(parent)
    end
    p
end
function OperationStruct!(varnames::Vector{Symbol}, ids::Vector{Int}, ls::LoopSet, op::Operation)
    instr = instruction(op)
    ld = loopdeps_uint(ls, op)
    rd = reduceddeps_uint(ls, op)
    cd = childdeps_uint(ls, op)
    p = parents_uint(ls, op)
    array = accesses_memory(op) ? findmatchingarray(ls, op.ref) : 0x00
    ids[identifier(op)] = id = findindoradd!(varnames, name(op))
    OperationStruct(
        ld, rd, cd, p, op.node_type, array, id
    )
end
## turn a LoopSet into a type object which can be used to reconstruct the LoopSet.

function loop_boundary(loop::Loop)
    startexact = loop.startexact
    stopexact = loop.stopexact
    if startexact & stopexact
        Expr(:call, Expr(:curly, lv(:StaticUnitRange), loop.starthint, loop.stophint))
    elseif startexact
        Expr(:call, Expr(:curly, lv(:StaticLowerUnitRange), loop.starthint), loop.stopsym)
    elseif stopexact
        Expr(:call, Expr(:curly, lv(:StaticUpperUnitRange), loop.stophint), loop.startsym)
    else
        Expr(:call, :(:), loop.startsym, loop.stopsym)
    end
end

function loop_boundaries(ls::LoopSet)
    lbd = Expr(:tuple)
    foreach(loop -> push!(lbd.args, loop_boundary(loop)), ls.loops)
    lbd
end

function argmeta_and_consts_description(ls::LoopSet, arraysymbolinds)
    Expr(
        :curly, :Tuple,
        length(arraysymbolinds),
        Expr(:curly, :Tuple, ls.outer_reductions...),
        Expr(:curly, :Tuple, first.(ls.preamble_symsym)...),
        Expr(:curly, :Tuple, ls.preamble_symint...),
        Expr(:curly, :Tuple, ls.preamble_symfloat...),
        Expr(:curly, :Tuple, ls.preamble_zeros...),
        Expr(:curly, :Tuple, ls.preamble_funcofeltypes...)
    )
end

function loopset_return_value(ls::LoopSet, ::Val{extract}) where {extract}
    @assert !iszero(length(ls.outer_reductions))
    if isone(length(ls.outer_reductions))
        op = getop(ls, ls.outer_reductions[1])
        if extract
            if (isu₁unrolled(op) | isu₂unrolled(op))
                Expr(:call, :extract_data, Symbol(mangledvar(op), 0))
            else
                Expr(:call, :extract_data, mangledvar(op))
            end
        else
            Symbol(mangledvar(op), 0)
        end
    else#if length(ls.outer_reductions) > 1
        ret = Expr(:tuple)
        ops = operations(ls)
        for or ∈ ls.outer_reductions
            op = ops[or]
            if extract
                push!(ret.args, Expr(:call, :extract_data, Symbol(mangledvar(op), 0)))
            else
                push!(ret.args, Symbol(mangledvar(ops[or]), 0))
            end
        end
        ret
    end
end

function add_reassigned_syms!(q::Expr, ls::LoopSet)
    for op ∈ operations(ls)
        if isconstant(op)
            instr = instruction(op)
            (instr == LOOPCONSTANT || instr.mod === :numericconstant) || push!(q.args, instr.instr)
        end
    end
end
function add_external_functions!(q::Expr, ls::LoopSet)
    for op ∈ operations(ls)
        if iscompute(op)
            instr = instruction(op)
            if instr.mod !== :LoopVectorization
                push!(q.args, instr.instr)
            end
        end
    end
end

function check_if_empty(ls::LoopSet, q::Expr)
    lb = loop_boundaries(ls)
    Expr(:if, Expr(:call, :!, Expr(:call, :any, :isempty, lb)), q)
end

# Try to condense in type stable manner
function generate_call(ls::LoopSet, inline_unroll::NTuple{3,Int8}, debug::Bool = false)
    operation_descriptions = Expr(:curly, :Tuple)
    varnames = Symbol[]; ids = Vector{Int}(undef, length(operations(ls))) 
    for op ∈ operations(ls)
        instr = instruction(op)
        push!(operation_descriptions.args, QuoteNode(instr.mod))
        push!(operation_descriptions.args, QuoteNode(instr.instr))
        push!(operation_descriptions.args, OperationStruct!(varnames, ids, ls, op))
    end
    arraysymbolinds = Symbol[]
    arrayref_descriptions = Expr(:curly, :Tuple)
    foreach(ref -> push!(arrayref_descriptions.args, ArrayRefStruct(ls, ref, arraysymbolinds, ids)), ls.refs_aliasing_syms)
    argmeta = argmeta_and_consts_description(ls, arraysymbolinds)
    loop_bounds = loop_boundaries(ls)
    loop_syms = Expr(:curly, :Tuple, map(QuoteNode, ls.loopsymbols)...)
    inline, u₁, u₂ = inline_unroll

    func = debug ? lv(:_avx_loopset_debug) : lv(:_avx_!)
    lbarg = debug ? Expr(:call, :typeof, loop_bounds) : loop_bounds
    q = Expr(
        :call, func, Expr(:call, Expr(:curly, :Val, Expr(:tuple, inline, u₁, u₂, Expr(:call, lv(:unwrap), VECTORWIDTHSYMBOL)))),
        operation_descriptions, arrayref_descriptions, argmeta, loop_syms, lbarg
    )
    debug && deleteat!(q.args, 2)
    foreach(ref -> push!(q.args, vptr(ref)), ls.refs_aliasing_syms)

    foreach(is -> push!(q.args, last(is)), ls.preamble_symsym)
    append!(q.args, arraysymbolinds)
    add_reassigned_syms!(q, ls)
    add_external_functions!(q, ls)
    debug && return q
    vecwidthdefq = Expr(:block)
    define_eltype_vec_width!(vecwidthdefq, ls, nothing)
    Expr(:block, vecwidthdefq, q)
end


"""
    check_args(::Vararg{AbstractArray})


LoopVectorization will optimize an `@avx` loop if `check_args` on each on the indexed abstract arrays returns true.
It returns true for `AbstractArray{T}`s when `check_type(T) == true` and the array or its parent is a `StridedArray` or `AbstractRange`.

To provide support for a custom array type, ensure that `check_args` returns true, either through overloading it or subtyping `DenseArray`.
Additionally, define `pointer` and `stride` methods.
"""
@inline check_args(A::SubArray{T,N,P,I}) where {T,N,P,I<:Tuple{Vararg{Union{Int,Colon,AbstractRange}}}} = check_args(parent(A))
@inline check_args(A::OffsetArray) = check_args(parent(A))
@inline check_args(A::Adjoint) = check_args(parent(A))
@inline check_args(A::Transpose) = check_args(parent(A))
@inline check_args(A::PermutedDimsArray) = check_args(parent(A))
@inline check_args(A::StridedArray) = check_type(eltype(A))
@inline check_args(A::AbstractRange) = check_type(eltype(A))
@inline check_args(A::BitVector) = true
@inline check_args(A::BitMatrix) = true
@inline function check_args(A::AbstractArray)
    M = parentmodule(typeof(A))
    if parent(A) === A # SparseMatrix, StaticArray, etc
        false
    elseif M === Base || M === Core || M ===LinearAlgebra
        # reshapes which aren't StridedArrays, plus UpperTriangular, etc.
        false
    else
        check_args(parent(A)) # PermutedDimsArray, NamedDimsArray
    end
end
@inline check_args(A::VectorizationBase.AbstractStridedPointer{T}) where {T} = check_type(T)
@inline check_args(A, Bs...) = check_args(A) && check_args(Bs...)
"""
    check_type(::Type{T}) where {T}

Returns true if the element type is supported.
"""
check_type(::Type{T}) where {T <: NativeTypes} = true
check_type(::Type{T}) where {T} = false

function check_args_call(ls::LoopSet)
    q = Expr(:call, lv(:check_args))
    append!(q.args, ls.includedactualarrays)
    q
end

make_fast(q) = Expr(:macrocall, Symbol("@fastmath"), LineNumberNode(@__LINE__,Symbol(@__FILE__)), q)
make_crashy(q) = Expr(:macrocall, Symbol("@inbounds"), LineNumberNode(@__LINE__,Symbol(@__FILE__)), q)

function setup_call_inline(ls::LoopSet, inline::Int8 = zero(Int8), U::Int8 = zero(Int8), T::Int8 = zero(Int8))
    call = generate_call(ls, (inline,U,T))
    noouterreductions = iszero(length(ls.outer_reductions))
    if noouterreductions
        q = Expr(:block,gc_preserve(ls, call))
        append!(ls.preamble.args, q.args)
        return ls.preamble
    end
    retv = loopset_return_value(ls, Val(false))
    outer_reducts = Expr(:local)
    q = Expr(:block,gc_preserve(ls, Expr(:(=), retv, call)))
    for or ∈ ls.outer_reductions
        op = ls.operations[or]
        var = name(op)
        # push!(call.args, Symbol("##TYPEOF##", var))
        mvar = mangledvar(op)
        instr = instruction(op)
        out = Symbol(mvar, 0)
        push!(outer_reducts.args, out)
        push!(q.args, Expr(:(=), var, Expr(:call, lv(reduction_scalar_combine(instr)), out, var)))
    end
    pushpreamble!(ls, outer_reducts)
    append!(ls.preamble.args, q.args)
    ls.preamble
end
function setup_call_debug(ls::LoopSet)
    # avx_loopset(instr, ops, arf, AM, LB, vargs)
    
    pushpreamble!(ls, generate_call(ls, (zero(Int8),zero(Int8),zero(Int8)), true))
    Expr(:block, ls.prepreamble, ls.preamble)
end
function setup_call(ls::LoopSet, q = nothing, inline::Int8 = zero(Int8), check_empty::Bool = false, u₁::Int8 = zero(Int8), u₂::Int8 = zero(Int8))
    # We outline/inline at the macro level by creating/not creating an anonymous function.
    # The old API instead was based on inlining or not inline the generated function, but
    # the generated function must be inlined into the initial loop preamble for performance reasons.
    # Creating an anonymous function and calling it also achieves the outlining, while still
    # inlining the generated function into the loop preamble.
    call = setup_call_inline(ls, inline, u₁, u₂)
    call = check_empty ? check_if_empty(ls, call) : call
    isnothing(q) && return Expr(:block, ls.prepreamble, call)
    Expr(:block, ls.prepreamble, Expr(:if, check_args_call(ls), call, make_crashy(make_fast(q))))
end
