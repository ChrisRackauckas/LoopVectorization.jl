using LoopVectorization
using Test
# T = Float32
@testset "GEMV" begin
    # Unum, Tnum = LoopVectorization.VectorizationBase.REGISTER_COUNT == 16 ? (3, 4) : (4, 6)
    Unum, Tnum = LoopVectorization.VectorizationBase.REGISTER_COUNT == 16 ? (2, 6) : (2, 10)
    gemvq = :(for i ∈ eachindex(y)
              yᵢ = 0.0
              for j ∈ eachindex(x)
              yᵢ += A[i,j] * x[j]
              end
              y[i] = yᵢ
              end)
    lsgemv = LoopVectorization.LoopSet(gemvq);
    if LoopVectorization.REGISTER_COUNT != 8
        @test LoopVectorization.choose_order(lsgemv) == (Symbol[:i, :j], :j, :i, :i, Unum, Tnum)
    end
    
    function mygemv!(y, A, x)
        @inbounds for i ∈ eachindex(y)
            yᵢ = zero(eltype(y))
            @simd for j ∈ eachindex(x)
                yᵢ += A[i,j] * x[j]
            end
            y[i] = yᵢ
        end
    end
    function mygemvavx!(y, A, x)
        @avx for i ∈ eachindex(y)
            yᵢ = zero(eltype(y))
            for j ∈ eachindex(x)
                yᵢ += A[i,j] * x[j]
            end
            y[i] = yᵢ
        end
    end
    function mygemvavx_range!(y, A, x)
        rng1, rng2 = axes(A)
        @avx for i ∈ rng1
            yᵢ = zero(eltype(y))
            for j ∈ rng2
                yᵢ += A[i,j] * x[j]
            end
            y[i] = yᵢ
        end
    end
    # q = :(for i ∈ eachindex(y)
    #       yᵢ = zero(eltype(y))
    #       for j ∈ eachindex(x)
    #       yᵢ += A[i,j] * x[j]
    #       end
    #       y[i] = yᵢ
    #       end);
    # ls = LoopVectorization.LoopSet(q);
    function mygemv_avx!(y, A, x)
        # Need to test 0s somewhere!
        @_avx for i ∈ eachindex(y)
            yᵢ = 0.0#zero(eltype(y))
            for j ∈ eachindex(x)
                yᵢ += A[i,j] * x[j]
            end
            y[i] = yᵢ
        end
    end
    # q = :(for i ∈ eachindex(y)
    #         yᵢ = 0.0#zero(eltype(y))
    #         for j ∈ eachindex(x)
    #             yᵢ += A[i,j] * x[j]
    #         end
    #         y[i] = yᵢ
    #   end);
    # ls = LoopVectorization.LoopSet(q);
    # LoopVectorization.lower(ls, 2, 2, 0)


    function AtmulvB!(G, B,κ)
        d = size(G,1)
        @inbounds for d1=1:d
            G[d1,κ] = B[1,d1]*B[1,κ]
            for d2=2:d
                G[d1,κ] += B[d2,d1]*B[d2,κ]
            end
        end
    end
    function AtmulvBavx1!(G, B,κ)
        d = size(G,1)
        z = zero(eltype(G))
        @avx for d1=1:d
            G[d1,κ] = z
            for d2=1:d
                G[d1,κ] += B[d2,d1]*B[d2,κ]
            end
        end
    end
    function AtmulvBavx2!(G, B,κ)
        d = size(G,1)
        @avx for d1=1:d
            z = zero(eltype(G))
            for d2=1:d
                z += B[d2,d1]*B[d2,κ]
            end
            G[d1,κ] = z
        end
    end
    function AtmulvBavx3!(G, B,κ)
        d = size(G,1)
        @avx unroll=(2,2) for d1=1:d
            G[d1,κ] = B[1,d1]*B[1,κ]
            for d2=2:d
                G[d1,κ] += B[d2,d1]*B[d2,κ]
            end
        end
    end
    
    function AtmulvB_avx1!(G, B,κ)
        d = size(G,1)
        z = zero(eltype(G))
        @_avx for d1=1:d
            G[d1,κ] = z
            for d2=1:d
                G[d1,κ] += B[d2,d1]*B[d2,κ]
            end
        end
    end
    function AtmulvB_avx2!(G, B,κ)
        d = size(G,1)
        @_avx for d1=1:d
            z = zero(eltype(G))
            for d2=1:d
                z += B[d2,d1]*B[d2,κ]
            end
            G[d1,κ] = z
        end
    end
    gemvq = :(for d1=1:d
              z = zero(eltype(G))
              for d2=1:d
              z += B[d2,d1]*B[d2,κ]
              end
              G[d1,κ] = z
              end)
    lsgemv = LoopVectorization.LoopSet(gemvq);
    if LoopVectorization.REGISTER_COUNT != 8
        @test LoopVectorization.choose_order(lsgemv) == ([:d1,:d2], :d2, :d1, :d2, Unum, Tnum)
    end
    function AtmulvB_avx3!(G, B,κ)
        d = size(G,1)
        @_avx for d1=1:d
            G[d1,κ] = B[1,d1]*B[1,κ]
            for d2=2:d
                G[d1,κ] += B[d2,d1]*B[d2,κ]
            end
        end
    end
    pq = :(for d1=1:d
           G[d1,κ] = B[1,d1]*B[1,κ]
           for d2=2:d
           G[d1,κ] += B[d2,d1]*B[d2,κ]
           end
           end)
    lsp = LoopVectorization.LoopSet(pq);
    if LoopVectorization.REGISTER_COUNT != 8
        @test LoopVectorization.choose_order(lsp) == ([:d1, :d2], :d2, :d1, :d2, Unum, Tnum)
    end
    # lsp.preamble_symsym

    function hhavx!(A::AbstractVector{T}, B, C, D) where {T}
        L = T(length(axes(B,2)));
        @avx for i in axes(A, 1)
            A[i] = A[i] + D[i] * L
            for j = axes(B, 2)
                B[i, j] = B[i, j] + D[i]
                C[j] = C[j] + D[i] 
            end
        end
    end
    function hh!(A::AbstractVector{T}, B, C, D) where {T}
        L = T(length(axes(B,2)));
        @inbounds @fastmath for i in axes(A, 1)
            A[i] = A[i] + D[i] * L
            for j = axes(B, 2)
                B[i, j] = B[i, j] + D[i]
                C[j] = C[j] + D[i] 
            end
        end
    end

    M, K, N = 51, 49, 61
    for T ∈ (Float32, Float64, Int32, Int64)
        @show T, @__LINE__
        TC = sizeof(T) == 4 ? Float32 : Float64
        R = T <: Integer ? (T(-1000):T(1000)) : T
        Afull = fill(T(10^3), 3M, 3K);
        xfull = fill(T(1), 3K);
        y1full = fill(TC(-1000), 3M); y2full = copy(y1full);

        A = view(Afull, M .+ (1:M), K .+ (1:K)); A .= rand.(Ref(R));
        x = view(xfull, K .+ (1:K)); x .= rand.(Ref(R));
        y1 = view(y1full, M .+ (1:M));
        y2 = view(y2full, M .+ (1:M));

        # A = rand(R, M, K);
        # x = rand(R, K);
        # y1 = Vector{TC}(undef, M); y2 = similar(y1);

        mygemv!(y1, A, x);
        mygemvavx!(y2, A, x);
        @test y1full ≈ y2full
        fill!(y2, -9999); mygemv_avx!(y2, A, x);
        @test y1full ≈ y2full
        fill!(y2, -9999);
        mygemvavx_range!(y2, A, x)
        @test y1full ≈ y2full

        Abit = A .> 0.5;
        fill!(y2, -9999); mygemv_avx!(y2, Abit, x);
        @test y2 ≈ Abit * x
        fill!(y2, -9999); mygemvavx!(y2, Abit, x);
        @test y2 ≈ Abit * x
        xbit = x .> 0.5;
        fill!(y2, -9999); mygemv_avx!(y2, A, xbit);
        @test y2 ≈ A * xbit
        fill!(y2, -9999); mygemvavx!(y2, A, xbit);
        @test y2 ≈ A * xbit

        # Check for out of bounds stores
        fill!(y1, 0); fill!(y2, 0); @test y1full ≈ y2full
        
        B = rand(R, N, N);
        G1 = Matrix{TC}(undef, N, 1);
        G2 = similar(G1);
        # G3 = similar(G1);
        AtmulvB!(G1,B,1);
        AtmulvBavx1!(G2,B,1);
        @test G1 ≈ G2
        fill!(G2, TC(NaN)); AtmulvBavx2!(G2,B,1);

        @test G1 ≈ G2
        fill!(G2, TC(NaN)); AtmulvBavx3!(G2,B,1);
        @test G1 ≈ G2
        fill!(G2, TC(NaN)); AtmulvB_avx1!(G2,B,1);
        @test G1 ≈ G2
        fill!(G2, TC(NaN)); AtmulvB_avx2!(G2,B,1);
        @test G1 ≈ G2
        fill!(G2, TC(NaN)); AtmulvB_avx3!(G2,B,1);
        @test G1 ≈ G2

        D = rand(R, M);
        B1 = rand(R, M,N); B2 = copy(B1);
        C1 = rand(R, N); C2 = copy(C1);
        A1 = rand(R, size(D)...); A2 = copy(A1);
        hh!(A1, B1, C1, D)
        hhavx!(A2, B2, C2, D)
        @test B1 ≈ B2
        @test C1 ≈ C2
        @test A1 ≈ A2

        
    end
end
