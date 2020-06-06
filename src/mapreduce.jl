
@inline vreduce(::typeof(+), v::VectorizationBase.AbstractSIMDVector) = vsum(v)
@inline vreduce(::typeof(*), v::VectorizationBase.AbstractSIMDVector) = vprod(v)
@inline vreduce(::typeof(max), v::VectorizationBase.AbstractSIMDVector) = vmaximum(v)
@inline vreduce(::typeof(min), v::VectorizationBase.AbstractSIMDVector) = vminimum(v)
@inline vreduce(op, v::VectorizationBase.AbstractSIMDVector) = _vreduce(op, v)
@inline _vreduce(op, v::VectorizationBase.AbstractSIMDVector) = _reduce(op, SVec(v))
@inline function _vreduce(op, v::SVec)
    isone(length(v)) && return v[1]
    a = op(v[1], v[2])
    for i ∈ 3:length(v)
        a = op(a, v[i])
    end
    a
end

function mapreduce_simple(f::F, op::OP, args::Vararg{DenseArray{<:NativeTypes},A}) where {F,OP,A}
    ptrargs = ntuple(a -> pointer(args[a]), Val(A))
    N = length(first(args))
    iszero(N) && throw("Length of vector is 0!")
    a_0 = f(vload.(ptrargs)...); i = 1
    while i < N
        a_0 = op(a_0, f(vload.(gep.(ptrargs, i))...)); i += 1
    end
    a_0
end


"""
    vmapreduce(f, op, A::DenseArray...)

Vectorized version of `mapreduce`. Applies `f` to each element of the arrays `A`, and reduces the result with `op`.
"""
function vmapreduce(f::F, op::OP, arg1::DenseArray{T}, args::Vararg{DenseArray{T},A}) where {F,OP,T<:NativeTypes,A}
    N = length(arg1)
    iszero(A) || @assert all(length.(args) .== N)
    W = VectorizationBase.pick_vector_width(T)
    V = VectorizationBase.pick_vector_width_val(T)
    if N < W
        mapreduce_simple(f, op, arg1, args...)
    else
        _vmapreduce(f, op, V, N, T, arg1, args...)
    end
end
function _vmapreduce(f::F, op::OP, ::Val{W}, N, ::Type{T}, args::Vararg{DenseArray{<:NativeTypes},A}) where {F,OP,A,W,T}
    ptrargs = pointer.(args)
    a_0 = f(vload.(Val{W}(), ptrargs)...); i = W
    if N ≥ 4W
        a_1 = f(vload.(Val{W}(), gep.(ptrargs, i))...); i += W
        a_2 = f(vload.(Val{W}(), gep.(ptrargs, i))...); i += W
        a_3 = f(vload.(Val{W}(), gep.(ptrargs, i))...); i += W
        while i < N - ((W << 2) - 1)
            a_0 = op(a_0, f(vload.(Val{W}(), gep.(ptrargs, i))...)); i += W
            a_1 = op(a_1, f(vload.(Val{W}(), gep.(ptrargs, i))...)); i += W
            a_2 = op(a_2, f(vload.(Val{W}(), gep.(ptrargs, i))...)); i += W
            a_3 = op(a_3, f(vload.(Val{W}(), gep.(ptrargs, i))...)); i += W
        end
        a_0 = op(a_0, a_1)
        a_2 = op(a_2, a_3)
        a_0 = op(a_0, a_2)
    end
    while i < N - (W - 1)
        a_0 = op(a_0, f(vload.(Val{W}(), gep.(ptrargs, i))...)); i += W
    end
    if i < N
        m = mask(T, N & (W - 1))
        a_0 = vifelse(m, op(a_0, f(vload.(Val{W}(), gep.(ptrargs, i))...)), a_0)
    end
    vreduce(op, a_0)
end

@inline vmapreduce(f, op, args...) = mapreduce(f, op, args...)


"""
    vreduce(op, destination, A::DenseArray...)

Vectorized version of `reduce`. Reduces the array `A` using the operator `op`.
"""
@inline vreduce(op, arg) = vmapreduce(identity, op, arg)

for (op, init) in zip((:+, :max, :min), (:zero, :identity, :identity))
    @eval function vreduce(::typeof($op), arg; dims = nothing)
        isnothing(dims) && return _vreduce($op, arg)
        @assert length(dims) == 1
        out = $init(arg[ntuple(d -> d == dims ? (1:1) : (1:size(arg, d)), ndims(arg))...])
        Rpre = CartesianIndices(axes(arg)[1:dims-1])
        Rpost = CartesianIndices(axes(arg)[dims+1:end])
        _vreduce_dims!(out, $op, Rpre, 1:size(arg, dims), Rpost, arg)
    end

    @eval function _vreduce_dims!(out, ::typeof($op), Rpre, is, Rpost, arg)
        @avx for Ipost in Rpost, i in is, Ipre in Rpre
            out[Ipre, 1, Ipost] = $op(out[Ipre, 1, Ipost], arg[Ipre, i, Ipost])
        end
        return out
    end

    @eval function _vreduce(::typeof($op), arg)
        s = $init(arg[1])
        @avx for i in 1:length(arg)
            s = $op(s, arg[i])
        end
        return s
    end
end
