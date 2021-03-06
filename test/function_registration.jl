# Each test here builds an ODEFunction including some user-registered
# Operations. The test simply checks that calling the ODEFunction
# appropriately calls the registered functions, whether the call is
# qualified (with a module name) or not.

# TEST: Function registration in a module.
# ------------------------------------------------
module MyModule
    using ModelingToolkit, DiffEqBase, LinearAlgebra, Test
    @parameters t x
    @variables u(t)
    @derivatives Dt'~t

    function do_something(a)
        a + 10
    end
    @register do_something(a)

    eq  = Dt(u) ~ do_something(x) + MyModule.do_something(x)
    sys = ODESystem([eq], t, [u], [x])
    fun = ODEFunction(sys)

    @test fun([0.5], [5.0], 0.) == [30.0]
end

# TEST: Function registration in a nested module.
# ------------------------------------------------
module MyModule2
    module MyNestedModule
        using ModelingToolkit, DiffEqBase, LinearAlgebra, Test
        @parameters t x
        @variables u(t)
        @derivatives Dt'~t

        function do_something_2(a)
            a + 20
        end
        @register do_something_2(a)

        eq  = Dt(u) ~ do_something_2(x) + MyNestedModule.do_something_2(x)
        sys = ODESystem([eq], t, [u], [x])
        fun = ODEFunction(sys)

        @test fun([0.5], [3.0], 0.) == [46.0]
    end
end

# TEST: Function registration outside any modules.
# ------------------------------------------------
using ModelingToolkit, DiffEqBase, LinearAlgebra, Test
@parameters t x
@variables u(t)
@derivatives Dt'~t

function do_something_3(a)
    a + 30
end
@register do_something_3(a)

eq  = Dt(u) ~ do_something_3(x) + (@__MODULE__).do_something_3(x)
sys = ODESystem([eq], t, [u], [x])
fun = ODEFunction(sys)

@test fun([0.5], [7.0], 0.) == [74.0]

# derivative
foo(x, y) = sin(x) * cos(y)
@parameters t; @variables x(t) y(t) z(t); @derivatives D'~t;
@register foo(x, y)
expr = foo(x, y)
@test expr.op === foo
@test expr.args[1] === x
@test expr.args[2] === y
ModelingToolkit.derivative(::typeof(foo), (x, y), ::Val{1}) = cos(x) * cos(y) # derivative w.r.t. the first argument
ModelingToolkit.derivative(::typeof(foo), (x, y), ::Val{2}) = -sin(x) * sin(y) # derivative w.r.t. the second argument
@test isequal(expand_derivatives(D(foo(x, y))), expand_derivatives(D(sin(x) * cos(y))))
