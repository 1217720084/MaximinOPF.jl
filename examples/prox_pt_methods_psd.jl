include("../src/MaximinOPF.jl")
include("psd_utils.jl")
using JuMP, MathOptInterface
using PowerModels
using Ipopt
using Mosek
using MosekTools
using CPLEX
#using SCIP
using LinearAlgebra
using SparseArrays
using Arpack
using Printf
PowerModels.silence()

### "Synopsis:"
#### "How does this relate to ALM, what happens if all constraints are relaxed in an ALM framework; ADMM??"
####    "Because we do not have a closed-form evaluation of the minimum eigenvalue function, we cannot apply ALM"
####    "Rather, the ALM approach is replaced with a proximal bundle method (PBM) approach; there are different PBM approaches to evaluate"
####    "Also we can project a Matrix to a PSD matrix w.r.t. the Frobenius inner product using eigendecomposition, so ADMM is applicable and is implemented also."

### "Assum the model has linear and PSD constraints"
### "Assume model already has a subproblem solver attached to it, "
###    "and that problem modifications will not otherwise cause reference to expressions and constraints to break"


 # "This function should be implemented to be recallable," 
 ### "so that a user can call this function multiple times to get ever more accurate solution information."
 ### "Return aggregated cuts for the PSD constraints, and a Dictionary of new constraints"
function solve_PSD_via_ADMM(model_info::Dict{String,Any}; max_n_iter=100, prox_t=1, io=Base.stdout)
    model = model_info["model"] 
    model_info["prox_t"] = prox_t
    model_info["prox_t_min"] = prox_t
    model_info["prox_t_max"] = 64*model_info["prox_t_min"]
    psd_expr = model[:psd_expr]
    prox_sign = model_info["prox_sign"] 
    PSD=model_info["psd_info"]

    for kk in keys(PSD)
        PSD[kk]["prox_t"] = prox_t
        PSD[kk]["expr_val_ctr"][:] .= 0
        PSD[kk]["proj_expr_val"][:] .= 0
        PSD[kk]["C"][:] .= 0
    end
    for ii=0:max_n_iter
        for kk in keys(PSD)
            PSD[kk]["quad_terms"] = sum( PSD[kk]["ip"][nn]*( psd_expr[kk,nn] - PSD[kk]["expr_val_ctr"][nn] )^2 for nn in 1:PSD[kk]["vec_len"]) 
            PSD[kk]["Lagr_terms"] = sum( PSD[kk]["ip"][nn]*PSD[kk]["C"][nn]*( psd_expr[kk,nn] - PSD[kk]["expr_val_ctr"][nn] )  for nn in 1:PSD[kk]["vec_len"]) 
        end
        @objective( model, model_info["obj_sense"], model[:linobj_expr]  
            + prox_sign * sum( PSD[kk]["Lagr_terms"] for kk in keys(PSD))
            + 0.5* prox_sign * prox_t*sum( PSD[kk]["quad_terms"] for kk in keys(PSD) )
        )
        try
            JuMP.optimize!( model) 
        catch exc
            println(exc)
	        println("Catching solve error, breaking from subiteration loop.")
            break
        end
        pd_res_val = 0.0
        for kk in keys(PSD)
            for nn=1:PSD[kk]["vec_len"]
                PSD[kk]["expr_val"][nn] = JuMP.value(psd_expr[kk,nn])
            end
            PSD[kk]["quad_term_vals"] = JuMP.value(PSD[kk]["quad_terms"])
            pd_res_val += PSD[kk]["quad_term_vals"] 
        end
        model_info["prox_val"]=JuMP.objective_value(model)
        model_info["solve_status"]=JuMP.termination_status(model)

        ADMMProjections(model_info;io=io)
        prim_res = trunc(sqrt(sum( PSD[kk]["prim_res_norm"]^2 for kk in keys(PSD)));digits=4)
        dual_res = trunc(sqrt(sum( PSD[kk]["dual_res_norm"]^2 for kk in keys(PSD)));digits=4)
        if mod(ii,10)==0 || ii==1
            println("\tsub-Iter $ii prox obj value: ",model_info["prox_val"]," in statu: ", 
                model_info["solve_status"]," p_res=",prim_res," d_res=",dual_res, " prox_t=",prox_t )
        end
        if sqrt(pd_res_val) < 1e-4
	        println("Sub-Iteratione $ii terminante, quia solutio relaxata est factibilis.")
            break
        else
#=
            if ii <= round(0.4*max_n_iter)
                model_info["prox_t"] = 0.01 
                prox_t = model_info["prox_t"]
            elseif ii <= round(0.6*max_n_iter)
                model_info["prox_t"] = 0.1 
                prox_t = model_info["prox_t"]
            else
                model_info["prox_t"] = 1 
                prox_t = model_info["prox_t"]
            end
            scale_fac = 2
            if mod(ii,10)==0 
                if prim_res > 10*dual_res
                    prox_t *= scale_fac
                    model_info["prox_t"] = prox_t
                elseif dual_res > 10*prim_res
                    prox_t /= scale_fac
                end
                prox_t = min( max(model_info["prox_t_min"],prox_t), model_info["prox_t_max"])
            end
            model_info["prox_t"] = prox_t
=#
        end
    end
    
end

function solveProxPtSP(model_info)
    PSD=model_info["psd_info"]
    model=model_info["model"]
    psd_expr = model[:psd_expr]
    for kk in keys(PSD)
        PSD[kk]["quad_terms"] = sum( PSD[kk]["ip"][nn]*( psd_expr[kk,nn] - PSD[kk]["expr_val_ctr"][nn] )^2 for nn in 1:PSD[kk]["vec_len"])
    end
    @objective( model, model_info["obj_sense"], model[:linobj_expr]  
        + 0.5* model_info["prox_sign"] * sum( PSD[kk]["prox_t"] * PSD[kk]["quad_terms"] for kk in keys(PSD) )
    )
    JuMP.optimize!( model) ### "Replace later with more simple solving technique, guaranteed to converge, like steepest descent, Newton-like?"

    for kk in keys(PSD)
        for nn=1:PSD[kk]["vec_len"]
            PSD[kk]["expr_val"][nn] = JuMP.value.(psd_expr[kk,nn])
        end
        for nn in keys(PSD[kk]["new_cuts"])
            PSD[kk]["new_cuts"][nn]["val"] = JuMP.value( PSD[kk]["new_cuts"][nn]["ref"] )
            PSD[kk]["new_cuts"][nn]["dual_val"] = JuMP.dual( PSD[kk]["new_cuts"][nn]["ref"] ) ###"Assumptions under which dual values exist"
        end
    end
    oldUB = model_info["opt_val"]
    model_info["opt_val"]=JuMP.objective_value(model)
    model_info["lin_objval"]=JuMP.value(model[:linobj_expr])
    model_info["solve_status"]=JuMP.termination_status(model)
end


 # "This function should be implemented to be recallable," 
 ### "so that a user can call this function multiple times to get ever more accurate solution information."
 ### "Return aggregated cuts for the PSD constraints, and a Dictionary of new constraints"
function solve_PSD_via_ProxPt(model_info::Dict{String,Any}; max_n_iter=100, prox_t=1, io=Base.stdout)
    psd_expr = model_info["model"][:psd_expr]
    prox_sign = model_info["prox_sign"] 
    PSD=model_info["psd_info"]

    for kk in keys(PSD)
        PSD[kk]["prox_t"] = prox_t
        empty!( PSD[kk]["new_cuts"])
    end

    for kk in keys(PSD)
        PSD[kk]["expr_val_ctr"][:] .= 0 
        PSD[kk]["eigval_ctr"] = 0
        PSD[kk]["C"][:] .= 0
    end
    model_info["lin_objval_ctr"] = model_info["prox_sign"]*1e20

    for ii=0:max_n_iter
        try
            solveProxPtSP(model_info)
        catch exc
            println(exc)
            println("Catching solve error, breaking from subiteration loop.")
            break
        end

        println("\tsub-Iter $ii Prox obj value: ",model_info["lin_objval"]," in statu: ", model_info["solve_status"])

        ### "TODO: incorporate ssc update of proximal center"
        PSDSubgradient(model_info;io=io)
        for kk in keys(PSD)
            ncuts=length(PSD[kk]["new_cuts"])
            PSD[kk]["new_cuts"][ncuts] = Dict{String,Any}()
            PSD[kk]["new_cuts"][ncuts]["ref"] = @constraint(PSD[kk]["model"], sum( PSD[kk]["ip"][nn]*PSD[kk]["sg"][nn]*psd_expr[kk,nn] for nn=1:PSD[kk]["vec_len"] ) >= 0) 
        end
        if prox_t > 0
            conditionallyUpdateProxCenter(model_info)
        end
        println("\t\tMin eig value is: ", minimum( PSD[kk]["min_eigval"] for kk in keys(PSD)), 
            ",\tmin center eig value is: ", minimum( PSD[kk]["eigval_ctr"] for kk in keys(PSD)))
        aggregateNewCuts(model_info)
        if model_info["total_sum_neg_eigs"] > -1e-4
	        println("Sub-Iteratione $ii terminante, quia solutio relaxata est factibilis.")
            break
        end
    end
end
