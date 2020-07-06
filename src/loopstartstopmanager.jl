


function uniquearrayrefs(ls::LoopSet)
    uniquerefs = ArrayReferenceMeta[]
    # for arrayref ∈ ls.refs_aliasing_syms
    for op ∈ operations(ls)
        arrayref = op.ref
        arrayref === NOTAREFERENCE && continue
        any(ref -> sameref(arrayref, ref), uniquerefs) || push!(uniquerefs, arrayref)
    end
    uniquerefs
end

otherindexunrolled(loopsym::Symbol, ind::Symbol, loopdeps::Vector{Symbol}) = (loopsym !== ind) && (loopsym ∈ loopdeps)
function otherindexunrolled(ls::LoopSet, ind::Symbol, ref::ArrayReferenceMeta)
    us = ls.unrollspecification[]
    u₁sym = names(ls)[us.u₁loopnum]
    u₂sym = us.u₂loopnum > 0 ? names(ls)[us.u₂loopnum] : Symbol("##undefined##")
    otherindexunrolled(u₁sym, ind, loopdependencies(ref)) || otherindexunrolled(u₂sym, ind, loopdependencies(ref))
end
multiple_with_name(n::Symbol, v::Vector{ArrayReferenceMeta}) = sum(ref -> n === vptr(ref), v) > 1
# TODO: DRY between indices_calculated_by_pointer_offsets and use_loop_induct_var
function indices_calculated_by_pointer_offsets(ls::LoopSet, ar::ArrayReferenceMeta)
    indices = getindices(ar)
    ls.isbroadcast[] && return fill(false, length(indices))
    looporder = names(ls)
    offset = isdiscontiguous(ar)
    gespinds = Expr(:tuple)
    out = Vector{Bool}(undef, length(indices))
    li = ar.loopedindex
    # @show ls.vector_width[]
    for i ∈ eachindex(li)
        ii = i + offset
        ind = indices[ii]
        # j = findfirst(isequal(ind), view(indices, offset+1:ii-1))
        # if !isnothing(j)
        #     out[i] = out[j - offset]
        #     continue
        # end
        if (!li[i]) || multiple_with_name(vptr(ar), ls.lssm[].uniquearrayrefs) ||
            (iszero(ls.vector_width[]) && isstaticloop(getloop(ls, ind)))# ||
            # ((ls.align_loops[] > 0) && (first(names(ls)) == ind))
            out[i] = false
        elseif (isone(ii) && (first(looporder) === ind))
            out[i] = otherindexunrolled(ls, ind, ar)
        else 
            out[i] = true
        end
    end
    out
end

"""
Returns a vector of length equal to the number of indices.
A value > 0 indicates which loop number that index corresponds to when incrementing the pointer.
A value < 0 indicates that abs(value) is the corresponding loop, and a `loopvalue` will be used.
"""
function use_loop_induct_var!(ls::LoopSet, q::Expr, ar::ArrayReferenceMeta, allarrayrefs::Vector{ArrayReferenceMeta})
    us = ls.unrollspecification[]
    li = ar.loopedindex
    looporder = reversenames(ls)
    uliv = Vector{Int}(undef, length(li))
    indices = getindices(ar)
    offset = first(indices) === Symbol("##DISCONTIGUOUSSUBARRAY##")
    if length(indices) != offset + length(li)
        println(ar)
        throw("Length of indices and length of offset do not match!")
    end
    isbroadcast = ls.isbroadcast[]
    gespinds = Expr(:tuple)
    offsetprecalc_descript = Expr(:tuple)
    use_offsetprecalc = false
    for i ∈ eachindex(li)
        ii = i + offset
        ind = indices[ii]
        # j = findfirst(isequal(ind), view(indices, offset+1:ii-1))
        # if !isnothing(j)
        #     j -= offset
        #     push!(gespinds.args, gespinds.args[j])
        #     uliv[i] = uliv[j]
        # else
        if (!li[i])
            uliv[i] = 0
            push!(gespinds.args, Expr(:call, lv(:Zero)))
            push!(offsetprecalc_descript.args, 0)
        elseif isbroadcast ||
            ((isone(ii) && (last(looporder) === ind)) && !(otherindexunrolled(ls, ind, ar)) ||
             multiple_with_name(vptr(ar), allarrayrefs)) ||
             (iszero(ls.vector_width[]) && isstaticloop(getloop(ls, ind)))# ||
             # ((ls.align_loops[] > 0) && (first(names(ls)) == ind))

            # Not doing normal offset indexing
            uliv[i] = -findfirst(isequal(ind), looporder)::Int
            push!(gespinds.args, Expr(:call, lv(:Zero)))
            push!(offsetprecalc_descript.args, 0) # not doing offset indexing, so push 0
        else
            uliv[i] = findfirst(isequal(ind), looporder)::Int
            loop = getloop(ls, ind)
            if loop.startexact
                push!(gespinds.args, Expr(:call, Expr(:curly, lv(:Static), loop.starthint - 1)))
            else
                push!(gespinds.args, Expr(:call, lv(:staticm1), loop.startsym))
            end
            if ind === names(ls)[us.vectorizedloopnum]
                push!(offsetprecalc_descript.args, 0)
            elseif (ind === names(ls)[us.u₁loopnum]) & (us.u₁ > 3)
                use_offsetprecalc = true
                push!(offsetprecalc_descript.args, us.u₁)
            elseif (ind === names(ls)[us.u₂loopnum]) & (us.u₂ > 3)
                use_offsetprecalc = true
                push!(offsetprecalc_descript.args, us.u₂)
            else
                push!(offsetprecalc_descript.args, 0)
            end
        end
    end
    if use_offsetprecalc
        push!(q.args, Expr(:(=), vptr(ar), Expr(:call, lv(:offsetprecalc), Expr(:call, lv(:gesp), vptr(ar), gespinds), Expr(:call, Expr(:curly, :Val, offsetprecalc_descript)))))
    else
        push!(q.args, Expr(:(=), vptr(ar), Expr(:call, lv(:gesp), vptr(ar), gespinds)))
    end    
    uliv
end

# Plan here is that we increment every unique array
function add_loop_start_stop_manager!(ls::LoopSet)
    q = Expr(:block)
    us = ls.unrollspecification[]
    # Presence of an explicit use of a loopinducation var means we should use that, so we look for one
    # TODO: replace first with only once you add Compat as a dep or drop support for older Julia versions
    loopinductvars = map(op -> first(loopdependencies(op)), filter(isloopvalue, operations(ls)))
    # Filtered ArrayReferenceMetas, we must increment each
    arrayrefs = uniquearrayrefs(ls)
    use_livs = map(ar -> use_loop_induct_var!(ls, q, ar, arrayrefs), arrayrefs)
    # loops, sorted from outer-most to inner-most
    looporder = reversenames(ls)
    # For each loop, we need to choose an induction variable
    nloops = length(looporder)
    # loopstarts = Vector{Vector{ArrayReferenceMeta}}(undef, nloops)
    loopstarts = fill(ArrayReferenceMeta[], nloops)
    terminators = Vector{Int}(undef, nloops) # zero is standard loop induct var
    # loopincrements = Vector{Vector{ArrayReferenceMeta}}(undef, nloops) # Not needed; copy of loopstarts
    # The purpose of the reminds thing here is to pick which of these to use for the terminator
    # We want to pick the one with the fewest outer loops with respect to this one, to minimize
    # the number of redefinitions of max-pointer used for the termination comparison.
    reached_indices = zeros(Int, length(arrayrefs))
    for (i,loopsym) ∈ enumerate(looporder) # iterates from outer to inner
        loopstartᵢ = ArrayReferenceMeta[]; arⱼ = 0; minrem = typemax(Int);
        ric = Tuple{Int,Int}[]
        for j ∈ eachindex(use_livs) # j is array ref number
            for (l,k) ∈ enumerate(use_livs[j])# l is index number, k is loop number
                if k == i
                    push!(loopstartᵢ, arrayrefs[j])
                    push!(ric, ((reached_indices[j] += 1), length(loopstartᵢ)))
                end
            end
        end
        loopstarts[i] = loopstartᵢ
        terminators[i] = if (loopsym ∈ loopinductvars) || (any(r -> any(isequal(-i), r), use_livs)) || iszero(length(loopstartᵢ))
            0
        else
            # @show i, loopsym loopdependencies.(operations(ls)) operations(ls)
            # @assert !iszero(length(loopstartᵢ))
            last(ric[argmin(first.(ric))]) # index corresponds to array ref's position in loopstart
        end
    end
    ls.lssm[] = LoopStartStopManager(
        reverse!(terminators), reverse!(loopstarts), arrayrefs
    )
    q
end
maxsym(ptr, sub) = Symbol(ptr, "##MAX##", sub, "##")
function pointermax(ls::LoopSet, ar::ArrayReferenceMeta, n::Int, sub::Int, isvectorized::Bool)::Expr
    pointermax(ls, ar, n, sub, isvectorized, getloop(ls, names(ls)[n]))
end
function pointermax(ls::LoopSet, ar::ArrayReferenceMeta, n::Int, sub::Int, isvectorized::Bool, loop::Loop)::Expr
    pointermax(ls, ar, n, sub, isvectorized, looplengthexpr(loop, n))::Expr
end
function pointermax(ls::LoopSet, ar::ArrayReferenceMeta, n::Int, sub::Int, isvectorized::Bool, stophint::Int)::Expr
    # @unpack u₁loopnum, u₂loopnum, vectorizedloopnum, u₁, u₂ = us
    loopsym = names(ls)[n]
    index = Expr(:tuple)
    for i ∈ getindicesonly(ar)
        if i === loopsym
            if iszero(sub)
                push!(index.args, stophint)
            elseif isvectorized
                if isone(sub)
                    push!(index.args, Expr(:call, lv(:valsub), stophint, VECTORWIDTHSYMBOL))
                else
                    push!(index.args, Expr(:call, lv(:vsub), stophint, Expr(:call, lv(:valmul), VECTORWIDTHSYMBOL, sub)))
                end
            else
                push!(index.args, stophint - sub)
            end
            ptr = vptr(ar)
            return Expr(:call, lv(:pointerforcomparison), ptr, index)
        else
            push!(index.args, Expr(:call, lv(:Zero)))
        end
    end
    @show ar, loopsym
end
function pointermax(ls::LoopSet, ar::ArrayReferenceMeta, n::Int, sub::Int, isvectorized::Bool, stopsym)::Expr
    # @unpack u₁loopnum, u₂loopnum, vectorizedloopnum, u₁, u₂ = us
    loopsym = names(ls)[n]
    index = Expr(:tuple)
    for i ∈ getindicesonly(ar)
        if i === loopsym
            if iszero(sub)
                push!(index.args, stopsym)
            elseif isvectorized
                if isone(sub)
                    push!(index.args, Expr(:call, lv(:valsub), stopsym, VECTORWIDTHSYMBOL))
                else
                    push!(index.args, Expr(:call, lv(:vsub), stopsym, Expr(:call, lv(:valmul), VECTORWIDTHSYMBOL, sub)))
                end
            else
                push!(index.args, Expr(:call, lv(:vsub), stopsym, sub))
            end
            return Expr(:call, lv(:pointerforcomparison), vptr(ar), index)
        else
            push!(index.args, Expr(:call, lv(:Zero)))
        end
    end
    @show ar, loopsym
end

function defpointermax(ls::LoopSet, ar::ArrayReferenceMeta, n::Int, sub::Int, isvectorized::Bool)::Expr
    Expr(:(=), maxsym(vptr(ar), sub), pointermax(ls, ar, n, sub, isvectorized))
end

function maxunroll(us::UnrollSpecification, n)
    @unpack u₁loopnum, u₂loopnum, u₁, u₂ = us
    if n == u₁loopnum# && u₁ > 1
        u₁
    elseif n == u₂loopnum# && u₂ > 1
        u₂
    else
        1
    end
end
    

function startloop(ls::LoopSet, us::UnrollSpecification, n::Int, submax = maxunroll(us, n))
    @unpack u₁loopnum, u₂loopnum, vectorizedloopnum, u₁, u₂ = us
    lssm = ls.lssm[]
    termind = lssm.terminators[n]
    ptrdefs = lssm.incrementedptrs[n]
    loopstart = Expr(:block)
    firstloop = n == num_loops(ls)
    for ar ∈ ptrdefs
        ptr = vptr(ar)
        push!(loopstart.args, Expr(:(=), ptr, ptr))
    end
    if iszero(termind)
        loopsym = names(ls)[n]
        push!(loopstart.args, startloop(getloop(ls, loopsym), loopsym))
    else
        isvectorized = n == vectorizedloopnum
        for sub ∈ 0:submax
            push!(loopstart.args, defpointermax(ls, ptrdefs[termind], n, sub, isvectorized))
        end
    end
    loopstart
end
function offset_ptr(ar::ArrayReferenceMeta, us::UnrollSpecification, loopsym::Symbol, n::Int, UF::Int, offsetinds::Vector{Bool})
    indices = getindices(ar)
    offset = first(indices) === DISCONTIGUOUS
    gespinds = Expr(:tuple)
    li = ar.loopedindex
    for i ∈ eachindex(li)
        ii = i + offset
        ind = indices[ii]
        if !offsetinds[i]
            push!(gespinds.args, Expr(:call, lv(:Zero)))
        elseif ind == loopsym
            incrementloopcounter!(gespinds, us, n, UF)
        else
            push!(gespinds.args, Expr(:call, lv(:Zero)))
        end
        ind == loopsym && break
    end
    Expr(:(=), vptr(ar), Expr(:call, lv(:gesp), vptr(ar), gespinds))
end
function incrementloopcounter(ls::LoopSet, us::UnrollSpecification, n::Int, UF::Int)
    @unpack u₁loopnum, u₂loopnum, vectorizedloopnum, u₁, u₂ = us
    lssm = ls.lssm[]
    ptrdefs = lssm.incrementedptrs[n]
    looporder = names(ls)
    loopsym = looporder[n]
    q = Expr(:block)
    termind = lssm.terminators[n]
    if iszero(termind) # increment liv
        push!(q.args, incrementloopcounter(us, n, loopsym, UF))
    end
    for (j,ar) ∈ enumerate(ptrdefs)
        offsetinds = indices_calculated_by_pointer_offsets(ls, ar)
        push!(q.args, offset_ptr(ar, us, loopsym, n, UF, offsetinds))
    end
    q
end
function terminatecondition(ls::LoopSet, us::UnrollSpecification, n::Int, inclmask::Bool, UF::Int)
    lssm = ls.lssm[]
    termind = lssm.terminators[n]
    if iszero(termind)
        loop = getloop(ls, names(ls)[n])
        return terminatecondition(loop, us, n, loop.itersymbol, inclmask, UF)
    end
    
    termar = lssm.incrementedptrs[n][termind]
    ptr = vptr(termar)
    # @show UF, isvectorized(us, n)
    if inclmask && isvectorized(us, n)
        Expr(:call, :<, callpointerforcomparison(ptr), maxsym(ptr, 0))
    else
        Expr(:call, :≤, callpointerforcomparison(ptr), maxsym(ptr, UF))
    end
end


