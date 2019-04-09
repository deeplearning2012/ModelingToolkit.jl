export ODESystem, ODEFunction


using Base: RefValue


isintermediate(eq::Equation) = !(isa(eq.lhs, Operation) && isa(eq.lhs.op, Differential))

function flatten_differential(O::Operation)
    @assert is_derivative(O) "invalid differential: $O"
    is_derivative(O.args[1]) || return (O.args[1], O.op.x, 1)
    (x, t, order) = flatten_differential(O.args[1])
    isequal(t, O.op.x) || throw(ArgumentError("non-matching differentials on lhs: $t, $(O.op.x)"))
    return (x, t, order + 1)
end


struct DiffEq  # dⁿx/dtⁿ = rhs
    x::Variable
    n::Int
    rhs::Expression
end
function to_diffeq(eq::Equation)
    isintermediate(eq) && throw(ArgumentError("intermediate equation received"))
    (x, t, n) = flatten_differential(eq.lhs)
    (isa(t, Operation) && isa(t.op, Variable) && isempty(t.args)) ||
        throw(ArgumentError("invalid independent variable $t"))
    (isa(x, Operation) && isa(x.op, Variable) && length(x.args) == 1 && isequal(first(x.args), t)) ||
        throw(ArgumentError("invalid dependent variable $x"))
    return t.op, DiffEq(x.op, n, eq.rhs)
end
Base.:(==)(a::DiffEq, b::DiffEq) = isequal((a.x, a.n, a.rhs), (b.x, b.n, b.rhs))

struct ODESystem <: AbstractSystem
    eqs::Vector{DiffEq}
    iv::Variable
    dvs::Vector{Variable}
    ps::Vector{Variable}
    jac::RefValue{Matrix{Expression}}
end

function ODESystem(eqs)
    reformatted = to_diffeq.(eqs)

    ivs = unique(r[1] for r ∈ reformatted)
    length(ivs) == 1 || throw(ArgumentError("one independent variable currently supported"))
    iv = first(ivs)

    deqs = [r[2] for r ∈ reformatted]

    dvs = [deq.x for deq ∈ deqs]
    ps = filter(vars(deq.rhs for deq ∈ deqs)) do x
        x.known & !isequal(x, iv)
    end |> collect

    ODESystem(deqs, iv, dvs, ps)
end
function ODESystem(deqs, iv, dvs, ps)
    jac = RefValue(Matrix{Expression}(undef, 0, 0))
    ODESystem(deqs, iv, dvs, ps, jac)
end

function _eq_unordered(a, b)
    length(a) === length(b) || return false
    n = length(a)
    idxs = Set(1:n)
    for x ∈ a
        idx = findfirst(isequal(x), b)
        idx === nothing && return false
        idx ∈ idxs      || return false
        delete!(idxs, idx)
    end
    return true
end
Base.:(==)(sys1::ODESystem, sys2::ODESystem) =
    _eq_unordered(sys1.eqs, sys2.eqs) && isequal(sys1.iv, sys2.iv) &&
    _eq_unordered(sys1.dvs, sys2.dvs) && _eq_unordered(sys1.ps, sys2.ps)
# NOTE: equality does not check cached Jacobian


function calculate_jacobian(sys::ODESystem)
    isempty(sys.jac[]) || return sys.jac[]  # use cached Jacobian, if possible
    rhs = [eq.rhs for eq ∈ sys.eqs]

    iv = sys.iv()
    dvs = [dv(iv) for dv ∈ sys.dvs]

    jac = expand_derivatives.(calculate_jacobian(rhs, dvs))
    sys.jac[] = jac  # cache Jacobian
    return jac
end

function generate_jacobian(sys::ODESystem; version::FunctionVersion = ArrayFunction)
    jac = calculate_jacobian(sys)
    return build_function(jac, sys.dvs, sys.ps, (sys.iv.name,); version = version)
end

struct DiffEqToExpr
    sys::ODESystem
end
function (f::DiffEqToExpr)(O::Operation)
    if isa(O.op, Variable)
        isequal(O.op, f.sys.iv) && return O.op.name  # independent variable
        O.op ∈ f.sys.dvs        && return O.op.name  # dependent variables
        isempty(O.args)         && return O.op.name  # 0-ary parameters
        return build_expr(:call, Any[O.op.name; f.(O.args)])
    end
    return build_expr(:call, Any[O.op; f.(O.args)])
end
(f::DiffEqToExpr)(x) = convert(Expr, x)

function generate_function(sys::ODESystem, vs, ps; version::FunctionVersion = ArrayFunction)
    rhss = [deq.rhs for deq ∈ sys.eqs]
    vs′ = [clean(v) for v ∈ vs]
    ps′ = [clean(p) for p ∈ ps]
    return build_function(rhss, vs′, ps′, (sys.iv.name,), DiffEqToExpr(sys); version = version)
end


function generate_ode_iW(sys::ODESystem, simplify=true; version::FunctionVersion = ArrayFunction)
    jac = calculate_jacobian(sys)

    gam = Variable(:gam; known = true)()

    W = LinearAlgebra.I - gam*jac
    W = SMatrix{size(W,1),size(W,2)}(W)
    iW = inv(W)

    if simplify
        iW = simplify_constants.(iW)
    end

    W = inv(LinearAlgebra.I/gam - jac)
    W = SMatrix{size(W,1),size(W,2)}(W)
    iW_t = inv(W)
    if simplify
        iW_t = simplify_constants.(iW_t)
    end

    vs, ps = sys.dvs, sys.ps
    iW_func   = build_function(iW  , vs, ps, (:gam,:t); version = version)
    iW_t_func = build_function(iW_t, vs, ps, (:gam,:t); version = version)

    return (iW_func, iW_t_func)
end

function DiffEqBase.ODEFunction(sys::ODESystem; version::FunctionVersion = ArrayFunction)
    expr = generate_function(sys; version = version)
    if version === ArrayFunction
        ODEFunction{true}(eval(expr))
    elseif version === SArrayFunction
        ODEFunction{false}(eval(expr))
    end
end
