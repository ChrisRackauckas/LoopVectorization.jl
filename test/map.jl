@testset "map" begin
    @inline foo(x, y) = exp(x) - sin(y)
    for T ∈ (Float32,Float64)
        @show T, @__LINE__
        for N ∈ [ 3, 371 ]
            a = rand(T, N); b = rand(T, N);
            c1 = map(foo, a, b);
            c2 = vmap(foo, a, b);
            @test c1 ≈ c2
            c2 = vmapt(foo, a, b);
            @test c1 ≈ c2
            c2 = vmapnt(foo, a, b);
            @test c1 ≈ c2
            c2 = vmapntt(foo, a, b);
            @test c1 ≈ c2
            fill!(c2, NaN); @views vmapnt!(foo, c2[2:end], a[2:end], b[2:end]);
            @test @views c1[2:end] ≈ c2[2:end]
            fill!(c2, NaN); @views vmapntt!(foo, c2[2:end], a[2:end], b[2:end]);
            @test @views c1[2:end] ≈ c2[2:end]
        end
        
        c = rand(T,100); x = rand(T,10^4); y1 = similar(x); y2 = similar(x);
        map!(xᵢ -> clenshaw(xᵢ, c), y1, x)
        vmap!(xᵢ -> clenshaw(xᵢ, c), y2, x)
        @test y1 ≈ y2
    end
end
