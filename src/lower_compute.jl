

function load_constrained(op, u₁loop, u₂loop, innermost_loop, forprefetch = false)
    loopdeps = loopdependencies(op)
    dependsonu₁ = u₁loop ∈ loopdeps
    dependsonu₂ = u₂loop ∈ loopdeps
    if forprefetch
        (dependsonu₁ & dependsonu₂) || return false
    end
    unrolleddeps = Symbol[]
    dependsonu₁ && push!(unrolleddeps, u₁loop)
    dependsonu₂ && push!(unrolleddeps, u₂loop)
    forprefetch && push!(unrolleddeps, innermost_loop)
    any(parents(op)) do opp
        isload(opp) && all(in(loopdependencies(opp)), unrolleddeps)
    end
end
function check_if_remfirst(ls, ua)
    usorig = ls.unrollspecification[]
    @unpack u₁, u₁loopsym, u₂loopsym, u₂max = ua
    u₁loop = getloop(ls, u₁loopsym)
    u₂loop = getloop(ls, u₂loopsym)
    if isstaticloop(u₁loop) && (usorig.u₁ != u₁)
        return true
    end
    if isstaticloop(u₂loop) && (usorig.u₂ != u₂max)
        return true
    end
    false
end
function sub_fmas(ls::LoopSet, op::Operation, ua::UnrollArgs)
    @unpack u₁, u₁loopsym, u₂loopsym, u₂max = ua
    !(load_constrained(op, u₁loopsym, u₂loopsym, first(names(ls))) || check_if_remfirst(ls, ua))
end

struct FalseCollection end
Base.getindex(::FalseCollection, i...) = false
function parent_unroll_status(op::Operation, u₁loop::Symbol, u₂loop::Symbol, ::Nothing)
    map(opp -> isunrolled_sym(opp, u₁loop), parents(op)), FalseCollection()
end
# function parent_unroll_status(op::Operation, u₁loop::Symbol, u₂loop::Symbol, ::Nothing)
#     vparents = parents(op);
#     parent_names = Vector{Symbol}(undef, length(vparents))
#     parents_u₁syms = Vector{Bool}(undef, length(vparents))
#     # parents_u₂syms = Vector{Bool}(undef, length(vparents))
#     for i ∈ eachindex(vparents)
#         parent_names[i], parents_u₁syms[i], _ = variable_name_and_unrolled(vparents[i], u₁loop, u₂loop, nothing)
#     end
#     parent_names, parents_u₁syms, FalseCollection()
# end
function parent_unroll_status(op::Operation, u₁loop::Symbol, u₂loop::Symbol, u₂iter::Int)
    vparents = parents(op);
    # parent_names = Vector{Symbol}(undef, length(vparents))
    parents_u₁syms = Vector{Bool}(undef, length(vparents))
    parents_u₂syms = Vector{Bool}(undef, length(vparents))
    for i ∈ eachindex(vparents)
        # parent_names[i], parents_u₁syms[i], parents_u₂syms[i] = variable_name_and_unrolled(vparents[i], u₁loop, u₂loop, u₂iter)
        parents_u₁syms[i], parents_u₂syms[i] = isunrolled_sym(vparents[i], u₁loop, u₂loop, u₂iter)
    end
    # parent_names, parents_u₁syms, parents_u₂syms
    parents_u₁syms, parents_u₂syms
end

# """
#     Requires a parents_op argument, because it may `===` parents(op), due to previous divergence, e.g. to handle unrolling.
# """
# function isreducingidentity!(q::Expr, op::Operation, parents_op::Vector{Operation}, U::Int, u₁loop::Symbol, u₂loop::Symbol, vectorized::Symbol, suffix)
#     vparents = copy(parents_op) # don't mutate the original!
#     for (i,opp) ∈ enumerate(parents_op)
#         @show opp vectorized ∈ loopdependencies(opp), vectorized ∈ reducedchildren(opp) # must reduce
#         @show vectorized, loopdependencies(opp), reducedchildren(opp) # must reduce
#         if vectorized ∈ loopdependencies(opp) || vectorized ∈ reducedchildren(opp) # must reduce
#             loopdeps = [l for l ∈ loopdependencies(opp) if l !== vectorized]
#             @show opp
#             reductinstruct = reduction_to_scalar(instruction(opp))
            
#             reducedparent = Operation(
#                 opp.identifier, gensym(opp.variable), opp.elementbytes, Instruction(:LoopVectorization, reductinstruct), opp.node_type,
#                 loopdeps, opp.reduced_deps, opp.parents, opp.ref, opp.reduced_children
#             )
#             pname,   pu₁,  pu₂ = variable_name_and_unrolled(opp, u₁loop, u₂loop, suffix)
#             rpname, rpu₁, rpu₂ = variable_name_and_unrolled(reducedparent, u₁loop, u₂loop, suffix)
#             @assert pu₁ == rpu₁ && pu₂ == rpu₂
#             if rpu₁
#                 for u ∈ 0:U-1
#                     push!(q.args, Expr(:(=), Symbol(rpname,u), Expr(:call, lv(reductinstruct), Symbol(pname,u))))
#                 end
#             else
#                 push!(q.args, Expr(:(=), rpname, Expr(:call, lv(reductinstruct), pname)))
#             end
#             vparents[i] = reducedparent
#         end
#     end
#     vparents
# end

function add_loopvalue!(instrcall::Expr, loopval::Symbol, vectorized::Symbol, u::Int)
    if loopval === vectorized
        if isone(u)
            push!(instrcall.args, Expr(:call, lv(:valadd), VECTORWIDTHSYMBOL, _MMind(Expr(:call, lv(:staticp1), loopval))))
        else
            push!(instrcall.args, Expr(:call, lv(:valmuladd), VECTORWIDTHSYMBOL, u, _MMind(Expr(:call, lv(:staticp1), loopval))))
        end
    else
        push!(instrcall.args, Expr(:call, lv(:vadd), loopval, u + 1))
    end
end
function add_loopvalue!(instrcall::Expr, loopval, ua::UnrollArgs, u::Int)
    @unpack u₁loopsym, u₂loopsym, vectorized, suffix = ua
    if u > 0 && loopval === u₁loopsym #parentsunrolled[n]
        add_loopvalue!(instrcall, loopval, vectorized, u)
    elseif !isnothing(suffix) && suffix > 0 && loopval === u₂loopsym
        add_loopvalue!(instrcall, loopval, vectorized, suffix)
    elseif loopval === vectorized
        push!(instrcall.args, _MMind(Expr(:call, lv(:staticp1), loopval)))
    else
        push!(instrcall.args, Expr(:call, lv(:staticp1), loopval))
    end
end

function lower_compute!(
    q::Expr, op::Operation, ls::LoopSet, ua::UnrollArgs, mask::Union{Nothing,Symbol,Unsigned} = nothing,
)
    @unpack u₁, u₁loopsym, u₂loopsym, vectorized, suffix = ua
    var = name(op)
    instr = instruction(op)
    parents_op = parents(op)
    nparents = length(parents_op)
    mvar, u₁unrolledsym, u₂unrolledsym = variable_name_and_unrolled(op, u₁loopsym, u₂loopsym, suffix)
    opunrolled = u₁unrolledsym || u₁loopsym ∈ loopdependencies(op)
    # parent_names, parents_u₁syms, parents_u₂syms = parent_unroll_status(op, u₁loop, u₂loop, suffix)
    parents_u₁syms, parents_u₂syms = parent_unroll_status(op, u₁loopsym, u₂loopsym, suffix)
    tiledouterreduction = if isnothing(suffix)
        -1
    else
        suffix_ = Symbol(suffix, :_)
        isouterreduction(op)
    end
    # parenttiled = isunrolled_sym.(parents_op, tiled, unrolled)
    # if instr.instr === :identity && name(first(parents_op)) === var && isone(length(parents_op))
    #     if (u₁unrolledsym == first(parents_u₁syms)) && ((!isnothing(suffix)) == parents_u₂syms[1])
    #         return
    #     end
    # end
    # unrollsym = isunrolled_sym(op, unrolled)
    if !opunrolled && any(parents_u₁syms) # TODO: Clean up this mess, refactor the naming code, putting it in one place and have everywhere else use it for easy equivalence.
        parents_op = copy(parents_op) # don't mutate the original!
        for i ∈ eachindex(parents_u₁syms)
            parents_u₁syms[i] || continue
            parents_u₁syms[i] = false
            parentop = parents_op[i]
            i == tiledouterreduction && isconstant(parentop) && continue
            newparentop = Operation(
                parentop.identifier, gensym(parentop.variable), parentop.elementbytes, parentop.instruction, parentop.node_type,
                parentop.dependencies, parentop.reduced_deps, parentop.parents, parentop.ref, parentop.reduced_children
            )
            parentname = mangledvar(parentop)
            newparentname = mangledvar(newparentop)
            parents_op[i] = newparentop
            if parents_u₂syms[i]
                parentname = Symbol(parentname, suffix_)
                newparentname = Symbol(newparentname, suffix_)
            end
            if isconstant(newparentop)
                push!(q.args, Expr(:(=), newparentname, Symbol(parentname, 0)))
            else
                for u ∈ 0:u₁-1
                    push!(q.args, Expr(:(=), Symbol(newparentname, u), Symbol(parentname, u)))
                end
                reduce_expr!(q, newparentname, Instruction(reduction_to_single_vector(instruction(newparentop))), u₁)
                push!(q.args, Expr(:(=), newparentname, Symbol(newparentname, 0)))
            end
        end
    end
    # cache unroll and tiling check of parents
    # not broadcasted, because we use frequent checks of individual bools
    # making BitArrays inefficient.
    # parentsyms = [opp.variable for opp ∈ parents(op)]
    Uiter = opunrolled ? u₁ - 1 : 0
    isreduct = isreduction(op)
    if !isnothing(suffix) && isreduct# && (iszero(suffix) || (ls.unrollspecification[].u₂ - 1 == suffix))
        # instrfid = findfirst(isequal(instr.instr), (:vfmadd, :vfnmadd, :vfmsub, :vfnmsub))
        instrfid = findfirst(isequal(instr.instr), (:vfmadd_fast, :vfnmadd_fast, :vfmsub_fast, :vfnmsub_fast))
        # want to instcombine when parent load's deps are superset
        # also make sure opp is unrolled
        if !isnothing(instrfid) && (opunrolled && u₁ > 1) && sub_fmas(ls, op, ua)
            specific_fmas = Base.libllvm_version >= v"11.0.0" ? (:vfmadd, :vfnmadd, :vfmsub, :vfnmsub) : (:vfmadd231, :vfnmadd231, :vfmsub231, :vfnmsub231)
            # specific_fmas = (:vfmadd231, :vfnmadd231, :vfmsub231, :vfnmsub231)
            instr = Instruction(specific_fmas[instrfid])
        end
    end
    reduceddeps = reduceddependencies(op)
    vecinreduceddeps = isreduct && vectorized ∈ reduceddeps
    maskreduct = !isnothing(mask) && vecinreduceddeps #any(opp -> opp.variable === var, parents_op)
    # if vecinreduceddeps && vectorized ∉ loopdependencies(op) # screen parent opps for those needing a reduction to scalar
    #     # parents_op = reduce_vectorized_parents!(q, op, parents_op, U, u₁loopsym, u₂loopsym, vectorized, suffix)
    #     isreducingidentity!(q, op, parents_op, U, u₁loopsym, u₂loopsym, vectorized, suffix) && return
    # end    
    # if a parent is not unrolled, the compiler should handle broadcasting CSE.
    # because unrolled/tiled parents result in an unrolled/tiled dependendency,
    # we handle both the tiled and untiled case here.
    # bajillion branches that go the same way on each iteration
    # but smaller function is probably worthwhile. Compiler could theoreically split anyway
    # but I suspect that the branches are so cheap compared to the cost of everything else going on
    # that smaller size is more advantageous.
    isvectorized = vectorized ∈ loopdependencies(op)
    modsuffix = 0
    for u ∈ 0:Uiter
        instrcall = callexpr(instr)
        varsym = if tiledouterreduction > 0 # then suffix !== nothing
            modsuffix = ((u + suffix*(Uiter + 1)) & 7)
            # modsuffix = suffix::Int#((u + suffix*(Uiter + 1)) & 7)
            # modsuffix = u
            # modsuffix = suffix # (suffix & 3)
            Symbol(mangledvar(op), modsuffix)
        elseif u₁unrolledsym
            Symbol(mvar, u)
        else
            mvar
        end
        for n ∈ 1:nparents
            if isloopvalue(parents_op[n])
                loopval = first(loopdependencies(parents_op[n]))
                add_loopvalue!(instrcall, loopval, ua, u)
            else
                parent = mangledvar(parents_op[n])
                if n == tiledouterreduction
                    parent = Symbol(parent, modsuffix)
                else
                    if parents_u₂syms[n]
                        parent = Symbol(parent, suffix_)
                    end
                    if parents_u₁syms[n]
                        parent = Symbol(parent, u)
                    end
                end
                if isvectorized && isload(parents_op[n]) && vectorized ∉ loopdependencies(parents_op[n]) && n != tiledouterreduction && !(parents_u₁syms[n] & parents_u₂syms[n])
                    broadcast_parent = Symbol(parent, "##broadcasted##")
                    if (parents_u₂syms[n] && iszero(u)) || (parents_u₁syms[n] && (isnothing(suffix) || iszero(suffix))) || (!(parents_u₁syms[n] | parents_u₂syms[n]) && iszero(u) && (isnothing(suffix) || iszero(suffix)))
                        push!(q.args, Expr(:(=), broadcast_parent, Expr(:call, lv(:vbroadcast), VECTORWIDTHSYMBOL, parent)))
                    end
                    parent = broadcast_parent
                end
                push!(instrcall.args, parent)
            end
        end
        if maskreduct && (u == Uiter || u₁loopsym !== vectorized) # only mask last
            if last(instrcall.args) == varsym
                pushfirst!(instrcall.args, lv(:vifelse))
                insert!(instrcall.args, 3, mask)
            elseif all(in(loopdependencies(op)), reduceddeps) || any(opp -> mangledvar(opp) === mangledvar(op), parents_op)
                push!(q.args, Expr(:(=), varsym, Expr(:call, lv(:vifelse), mask, instrcall, varsym)))
                continue
            end
        end
        if instr.instr === :identity && isone(length(parents_op))
            push!(q.args, Expr(:(=), varsym, instrcall.args[2]))
        elseif identifier(op) ∉ ls.outer_reductions && should_broadcast_op(op)
            push!(q.args, Expr(:(=), varsym, Expr(:call, lv(:vbroadcast), VECTORWIDTHSYMBOL, instrcall)))
        else
            push!(q.args, Expr(:(=), varsym, instrcall))
        end
    end
end


