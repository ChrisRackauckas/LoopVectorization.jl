using VectorizationBase: vnoaliasstore!


@inline vstoreadditivereduce!(args...) = vnoaliasstore!(args...)
@inline vstoremultiplicativevereduce!(args...) = vnoaliasstore!(args...)
@inline function vstoreadditivereduce!(ptr::VectorizationBase.AbstractStridedPointer, v::VectorizationBase.SVec, i::Tuple{Vararg{Union{Integer,Static}}})
    vnoaliasstore!(ptr, SIMDPirates.vsum(v), i)
end
@inline function vstoreadditivereduce!(ptr::VectorizationBase.AbstractStridedPointer, v::VectorizationBase.SVec, i::Tuple{Vararg{Union{Integer,Static}}}, m::VectorizationBase.Mask)
    vnoaliasstore!(ptr, SIMDPirates.vsum(v), i, m)
end
@inline function vstoremultiplicativevereduce!(ptr::VectorizationBase.AbstractStridedPointer, v::VectorizationBase.SVec, i::Tuple{Vararg{Union{Integer,Static}}})
    vnoaliasstore!(ptr, SIMDPirates.vprod(v), i)
end
@inline function vstoremultiplicativevereduce!(ptr::VectorizationBase.AbstractStridedPointer, v::VectorizationBase.SVec, i::Tuple{Vararg{Union{Integer,Static}}}, m::VectorizationBase.Mask)
    vnoaliasstore!(ptr, SIMDPirates.vprod(v), i, m)
end

function storeinstr(op::Operation, vectorized::Symbol)
    # defaultstoreop = :vstore!
    defaultstoreop = :vnoaliasstore!
    vectorized ∉ reduceddependencies(op) && return lv(defaultstoreop)
    vectorized ∈ loopdependencies(op) && return lv(defaultstoreop)
    # vectorized is not a loopdep, but is a reduced dep
    opp = first(parents(op))
    while vectorized ∉ loopdependencies(opp)
        oppold = opp
        for oppp ∈ parents(opp)
            if vectorized ∈ reduceddependencies(oppp)
                @assert opp !== oppp "More than one parent is a reduction over the vectorized variable."
                opp = oppp
            end
        end
        @assert opp !== oppold "Failed to find any parents "
    end
    instr_class = reduction_instruction_class(instruction(opp))
    instr = if instr_class === ADDITIVE_IN_REDUCTIONS
        :vstoreadditivereduce!
    elseif instr_class === MULTIPLICATIVE_IN_REDUCTIONS
        :vstoremultiplicativevereduce!
    else #FIXME
        defaultstoreop
    end
    lv(instr)
end

# const STOREOP = :vstore!
# variable_name(op::Operation, ::Nothing) = mangledvar(op)
# variable_name(op::Operation, suffix) = Symbol(mangledvar(op), suffix, :_)
# # variable_name(op::Operation, suffix, u::Int) = (n = variable_name(op, suffix); u < 0 ? n : Symbol(n, u))
function reduce_range!(q::Expr, toreduct::Symbol, instr::Instruction, Uh::Int, Uh2::Int)
    if 2Uh == Uh2
        for u ∈ 0:2:Uh2-1
            instrexpr = callexpr(instr)
            push!(instrexpr.args, Symbol(toreduct, u))
            push!(instrexpr.args, Symbol(toreduct, u + 1))
            push!(q.args, Expr(:(=), Symbol(toreduct, (u>>>1)), instrexpr))
        end
    else
        for u ∈ Uh:Uh2-2
            tru = Symbol(toreduct, u - Uh)
            instrexpr = callexpr(instr)
            push!(instrexpr.args, tru)
            push!(instrexpr.args, Symbol(toreduct, u))
            push!(q.args, Expr(:(=), tru, instrexpr))
        end
        for u ∈ 2Uh:Uh2-1
            tru = Symbol(toreduct, u - 2Uh)
            instrexpr = callexpr(instr)
            push!(instrexpr.args, tru)
            push!(instrexpr.args, Symbol(toreduct, u))
            push!(q.args, Expr(:(=), tru, instrexpr))
        end
    end
end
function reduce_range!(q::Expr, ls::LoopSet, Ulow::Int, Uhigh::Int)
    for or ∈ ls.outer_reductions
        op = ls.operations[or]
        var = mangledvar(op)
        instr = Instruction(reduction_to_single_vector(op.instruction))
        reduce_range!(q, var, instr, Ulow, Uhigh)
    end
end

function reduce_expr!(q::Expr, toreduct::Symbol, instr::Instruction, U::Int)
    U == 1 && return nothing
    @assert U > 1 "U = $U somehow < 1"
    instr = Instruction(reduction_to_single_vector(instr))
    Uh2 = U
    iter = 0
    while true # combine vectors
        Uh = Uh2 >> 1
        reduce_range!(q, toreduct, instr, Uh, Uh2)
        Uh == 1 && break
        Uh2 = Uh
        iter += 1; iter > 4 && throw("Oops! This seems to be excessive unrolling.")
    end
    nothing
end

# pvariable_name(op::Operation, ::Nothing) = mangledvar(first(parents(op)))
# pvariable_name(op::Operation, ::Nothing, ::Symbol) = mangledvar(first(parents(op)))
# pvariable_name(op::Operation, suffix) = Symbol(pvariable_name(op, nothing), suffix, :_)
# function pvariable_name(op::Operation, suffix, tiled::Symbol)
#     parent = first(parents(op))
#     mname = mangledvar(parent)
#     tiled ∈ loopdependencies(parent) ? Symbol(mname, suffix, :_) : mname
# end


function lower_conditionalstore_scalar!(
    q::Expr, op::Operation, ua::UnrollArgs, mask::Union{Nothing,Symbol,Unsigned}, inds_calc_by_ptr_offset::Vector{Bool}
)
    @unpack u₁, u₁loopsym, u₂loopsym, vectorized, suffix = ua
    mvar, opu₁, opu₂ = variable_name_and_unrolled(first(parents(op)), u₁loopsym, u₂loopsym, suffix)
    # var = pvariable_name(op, suffix, tiled)
    cond = last(parents(op))
    condvar, condu₁ = condvarname_and_unroll(cond, u₁loopsym, u₂loopsym, suffix, opu₂)
    loopdeps = loopdependencies(op)
    opu₁ = u₁loopsym ∈ loopdeps
    ptr = vptr(op)
    for u ∈ 0:u₁-1
        varname = varassignname(mvar, u, opu₁)
        condvarname = varassignname(condvar, u, condu₁)
        td = UnrollArgs(ua, u)
        push!(q.args, Expr(:&&, condvarname, Expr(:call, storeinstr(op, vectorized), ptr, varname, mem_offset_u(op, td, inds_calc_by_ptr_offset))))
    end
    nothing
end
function lower_conditionalstore_vectorized!(
    q::Expr, op::Operation, ua::UnrollArgs, mask::Union{Nothing,Symbol,Unsigned}, isunrolled::Bool, inds_calc_by_ptr_offset::Vector{Bool}
)
    @unpack u₁, u₁loopsym, u₂loopsym, vectorized, suffix = ua
    loopdeps = loopdependencies(op)
    @assert vectorized ∈ loopdeps
    mvar, opu₁, opu₂ = variable_name_and_unrolled(first(parents(op)), u₁loopsym, u₂loopsym, suffix)
    # var = pvariable_name(op, suffix, tiled)
    if isunrolled
        umin = 0
        U = u₁
    else
        umin = -1
        U = 0
    end
    ptr = vptr(op)
    vecnotunrolled = vectorized !== u₁loopsym
    cond = last(parents(op))
    condvar, condu₁ = condvarname_and_unroll(cond, u₁loopsym, u₂loopsym, suffix, opu₂)
    # @show parents(op) cond condvar
    for u ∈ 0:U-1
        td = UnrollArgs(ua, u)
        name, mo = name_memoffset(mvar, op, td, opu₁, inds_calc_by_ptr_offset)
        condvarname = varassignname(condvar, u, condu₁)
        instrcall = Expr(:call, storeinstr(op, vectorized), ptr, name, mo)
        if mask !== nothing && (vecnotunrolled || u == U - 1)
            push!(instrcall.args, Expr(:call, :&, condvarname, mask))
        else
            push!(instrcall.args, condvarname)
        end
        push!(q.args, instrcall)
    end
end

function lower_store_scalar!(
    q::Expr, op::Operation, ua::UnrollArgs, mask::Union{Nothing,Symbol,Unsigned}, inds_calc_by_ptr_offset::Vector{Bool}
)
    @unpack u₁, u₁loopsym, u₂loopsym, vectorized, suffix = ua
    mvar, opu₁, opu₂ = variable_name_and_unrolled(first(parents(op)), u₁loopsym, u₂loopsym, suffix)
    ptr = vptr(op)
    # var = pvariable_name(op, suffix, tiled)
    # parentisunrolled = unrolled ∈ loopdependencies(first(parents(op)))
    for u ∈ 0:u₁-1
        varname = varassignname(mvar, u, opu₁)
        td = UnrollArgs(ua, u)
        push!(q.args, Expr(:call, storeinstr(op, vectorized), ptr, varname, mem_offset_u(op, td, inds_calc_by_ptr_offset)))
    end
    nothing
end
function lower_store_vectorized!(
    q::Expr, op::Operation, ua::UnrollArgs, mask::Union{Nothing,Symbol,Unsigned}, isunrolled::Bool, inds_calc_by_ptr_offset::Vector{Bool}
)
    @unpack u₁, u₁loopsym, u₂loopsym, vectorized, suffix = ua
    loopdeps = loopdependencies(op)
    @assert vectorized ∈ loopdeps
    mvar, opu₁, opu₂ = variable_name_and_unrolled(first(parents(op)), u₁loopsym, u₂loopsym, suffix)
    ptr = vptr(op)
    # var = pvariable_name(op, suffix, tiled)
    # parentisunrolled = unrolled ∈ loopdependencies(first(parents(op)))
    if isunrolled
        umin = 0
        U = u₁
    else
        umin = -1
        U = 0
    end
    vecnotunrolled = vectorized !== u₁loopsym
    for u ∈ umin:U-1
        td = UnrollArgs(ua, u)
        name, mo = name_memoffset(mvar, op, td, opu₁, inds_calc_by_ptr_offset)
        instrcall = Expr(:call, storeinstr(op, vectorized), ptr, name, mo)
        if mask !== nothing && (vecnotunrolled || u == U - 1)
            push!(instrcall.args, mask)
        end
        push!(q.args, instrcall)
    end
end
function lower_store!(
    q::Expr, ls::LoopSet, op::Operation, ua::UnrollArgs, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    @unpack u₁, u₁loopsym, u₂loopsym, vectorized, suffix = ua
    isunrolled₁ = isu₁unrolled(op) #u₁loopsym ∈ loopdependencies(op)
    # isunrolled₂ = isu₂unrolled(op)
    inds_calc_by_ptr_offset = indices_calculated_by_pointer_offsets(ls, op.ref)
    # if isunrolled₁ & ((!isnothing(suffix)) && isu₂unrolled(op))
    #     u₁ind = findfirst(isequal(u₁loopsym), loopdependencies(op))::Int
    #     u₂ind = findfirst(isequal(u₁loopsym), loopdependencies(op))::Int
    #     if inds_calc_by_ptr_offset[u₁ind] && inds_calc_by_ptr_offset[u₂ind]
    #         if u₁ind < u₂ind
    #             zero_offset = u₂ind
    #             gespind = gensym("gesp")
    #             # gesp by suffix
    #         else
    #             zero_offset = u₁ind
    #             if iszero(suffix) # gesp for each

    #             end
    #         end
    #     end
    # else        
    # end
    ua = UnrollArgs(ua, isunrolled₁ ? u₁ : 1)
    if instruction(op).instr !== :conditionalstore!
        if vectorized ∈ loopdependencies(op)
            lower_store_vectorized!(q, op, ua, mask, isunrolled₁, inds_calc_by_ptr_offset)
        else
            lower_store_scalar!(q, op, ua, mask, inds_calc_by_ptr_offset)
        end
    else
        if vectorized ∈ loopdependencies(op)
            lower_conditionalstore_vectorized!(q, op, ua, mask, isunrolled₁, inds_calc_by_ptr_offset)
        else
            lower_conditionalstore_scalar!(q, op, ua, mask, inds_calc_by_ptr_offset)
        end
    end
end


