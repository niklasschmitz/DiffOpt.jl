using Random
using MathOptInterface
using Dualization
using OSQP

const MOI = MathOptInterface
const MOIU = MathOptInterface.Utilities;

n = 20 # variable dimension
m = 15 # no of inequality constraints

x̂ = rand(n)
Q = rand(n, n)
Q = Q' * Q # ensure PSD
q = rand(n)
G = rand(m, n)
h = G * x̂ + rand(m);

model = MOI.instantiate(OSQP.Optimizer, with_bridge_type=Float64)
x = MOI.add_variables(model, n);

# define objective

quad_terms = MOI.ScalarQuadraticTerm{Float64}[]
for i in 1:n
    for j in i:n # indexes (i,j), (j,i) will be mirrored. specify only one kind
        push!(quad_terms, MOI.ScalarQuadraticTerm(Q[i,j],x[i],x[j]))
    end
end

objective_function = MOI.ScalarQuadraticFunction(MOI.ScalarAffineTerm.(q, x),quad_terms,0.0)
MOI.set(model, MOI.ObjectiveFunction{MOI.ScalarQuadraticFunction{Float64}}(), objective_function)
MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)

# maintain constrain to index map - will be useful later
constraint_map = Dict()

# add constraints
for i in 1:m
    ci = MOI.add_constraint(
        model,
        MOI.ScalarAffineFunction(MOI.ScalarAffineTerm.(G[i,:], x), 0.),MOI.LessThan(h[i])
    )
    constraint_map[ci] = i
end

MOI.optimize!(model)

@assert MOI.get(model, MOI.TerminationStatus()) in [MOI.LOCALLY_SOLVED, MOI.OPTIMAL]

x̄ = MOI.get(model, MOI.VariablePrimal(), x);

# objective value (predicted vs actual) sanity check
@assert 0.5*x̄'*Q*x̄ + q'*x̄  <= 0.5*x̂'*Q*x̂ + q'*x̂   

# NOTE: can't use Ipopt
# Ipopt.Optimizer doesn't supports accessing MOI.ObjectiveFunctionType

joint_object    = dualize(model)
dual_model_like = joint_object.dual_model # this is MOI.ModelLike, not an MOI.AbstractOptimizer; can't call optimizer on it
primal_dual_map = joint_object.primal_dual_map;

# copy the dual model objective, constraints, and variables to an optimizer
dual_model = MOI.instantiate(OSQP.Optimizer, with_bridge_type=Float64)
MOI.copy_to(dual_model, dual_model_like)

# solve dual
MOI.optimize!(dual_model);

# check if strong duality holds
@assert abs(MOI.get(model, MOI.ObjectiveValue()) - MOI.get(dual_model, MOI.ObjectiveValue())) <= 1e-1


#
# Verifying KKT Conditions
#

map = primal_dual_map.primal_con_dual_var;


# complimentary slackness  + dual feasibility
for con_index in keys(map)
    # NOTE: OSQP.Optimizer doesn't allows access to MOI.ConstraintPrimal
    #       That's why I defined a custom map 
    
    i   = constraint_map[con_index]
    μ_i = MOI.get(dual_model, MOI.VariablePrimal(), map[con_index][1])
    
    # μ[i] * (G * x - h)[i] = 0
    @assert abs(μ_i * (G[i,:]' * x̄ - h[i])) < 1e-2

    # μ[i] <= 0
    @assert μ_i <= 1e-2
end


# checking stationarity
for j in 1:n
    G_mu_sum = 0

    for con_index in keys(map)
        # NOTE: OSQP.Optimizer doesn't allows access to MOI.ConstraintPrimal
        #       That's why I defined a custom map 
        
        i = constraint_map[con_index]
        μ_i = MOI.get(dual_model, MOI.VariablePrimal(), map[con_index][1])

        G_mu_sum += μ_i * G[i,j]
    end

    @assert abs(G_mu_sum - (Q * x̄ + q)[j]) < 1e-2
end
