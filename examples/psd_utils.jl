include("../src/MaximinOPF.jl")
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
function prepare_psd_model_reformulation(model::JuMP.Model, model_info::Dict{String,Any}=Dict{String,Any}(); io=devnull)
    time_Start = time_ns()

    @expression(model, linobj_expr, objective_function(model, AffExpr))
    model_info["model"] = model
    model_info["opt_val"]=1e20
    model_info["lin_objval"]=1e20
    model_info["lin_objval_ctr"]=1e20
    model_info["prox_t_min"] = 1e-3
    model_info["prox_t_max"] = 1e1

    model_info["obj_sense"] = objective_sense(model)
    model_info["prox_sign"] = 1
    if model_info["obj_sense"]==MOI.MAX_SENSE
        model_info["prox_sign"] = -1
    end

    gatherPSDConInfo(model_info) ### "Sets the 'psd_info' entry of model_info"
    #add_artificial_var_bds(model_info; bd_mag=1, io=devnull)
	#add_psd_initial_cuts(model_info;io=io)
    removePSD_Constraints(model_info["psd_info"])
    
    time_End = (time_ns()-time_Start)/1e9
    println("Initializing finished after ", time_End," seconds.")
    return model_info
end

function bound_obj(model_info::Dict{String,Any}; bd_mag=1e3)
    model=model_info["model"]
    obj_sense = objective_sense(model)
    obj_expr=@expression(model, objective_function(model, AffExpr))
    @variable(model, objvar)
    if obj_sense==MOI.MAX_SENSE
        @constraint(model, obj_expr <= bd_mag)
        @constraint(model, objvar - obj_expr <= 0)
    elseif obj_sense==MOI.MIN_SENSE
        @constraint(model, obj_expr >= -bd_mag)
        @constraint(model, objvar - obj_expr >= 0)
    end
    @objective(model, obj_sense, objvar)
end

#=
function add_artificial_var_bds(model::JuMP.Model; bd_mag=1e3, io=Base.stdout)
    all_vars = JuMP.all_variables(model)
    n_vars = length(all_vars)
    var_ids = collect(1:n_vars)
    artificial_lb_var_ids=[]
    artificial_ub_var_ids=[]
    for vv in var_ids
        if !has_lower_bound(all_vars[vv])
            set_lower_bound(all_vars[vv], -bd_mag)
            #@constraint(model, all_vars[vv] >= -bd_mag)
            push!(artificial_lb_var_ids,vv)
            println(io,"Artificial LB of ",-bd_mag," for variable ",all_vars[vv])
        end
        if !has_upper_bound(all_vars[vv])
            set_upper_bound(all_vars[vv], bd_mag)
            #@constraint(model, all_vars[vv] <= bd_mag)
            push!(artificial_ub_var_ids,vv)
            println(io,"Artificial UB of ", bd_mag," for variable ",all_vars[vv])
        end
    end
    return artificial_lb_var_ids, artificial_ub_var_ids
end
function add_artificial_var_bds(model_info::Dict{String,Any}; bd_mag=1e0, io=Base.stdout)
    model = model_info["model"]
    all_vars = JuMP.all_variables(model)
    n_vars = length(all_vars)
    var_ids = collect(1:n_vars)
    artificial_lb_var_ids=[]
    artificial_ub_var_ids=[]
    for vv in var_ids
        if has_lower_bound(all_vars[vv])
            if !has_upper_bound(all_vars[vv])
                set_upper_bound(all_vars[vv], bd_mag)
                push!(artificial_ub_var_ids,vv)
            end
        elseif has_upper_bound(all_vars[vv])
            if !has_lower_bound(all_vars[vv])
                set_lower_bound(all_vars[vv], -bd_mag)
                push!(artificial_lb_var_ids,vv)
            end
        end
    end
    model_info["artificial_lb_var_ids"] = artificial_lb_var_ids
    model_info["artificial_ub_var_ids"] = artificial_ub_var_ids
end
=#

function print_var_bds(model_info::Dict{String,Any}; io=Base.stdout)
    model = model_info["model"]
    all_vars = JuMP.all_variables(model)
    n_vars = length(all_vars)
    var_ids = collect(1:n_vars)
    for vv in var_ids
        lb_str=""
        ub_str=""
        if JuMP.has_lower_bound(all_vars[vv])
            lb_str = string(lb_str," LB: ",JuMP.lower_bound(all_vars[vv]))
        end
        if JuMP.has_upper_bound(all_vars[vv])
            ub_str = string(ub_str," UB: ",JuMP.upper_bound(all_vars[vv]))
        end
        println(io,JuMP.name(all_vars[vv]),lb_str,ub_str)
    end
end

function add_artificial_var_bds(model_info; bd_mag=10, io=devnull)
    linobj_expr = objective_function(model_info["model"], AffExpr)
    list_art_lb_refs=[]
    list_art_ub_refs=[]
    for tt in keys(linobj_expr.terms)
#=
        if occursin("p", JuMP.name(tt)) || occursin("q", JuMP.name(tt)) || occursin("fromSOC", JuMP.name(tt)) || occursin("toSOC", JuMP.name(tt))
            bd_val=1
        else
            bd_val=bd_mag
        end
=#
        bd_val=bd_mag
        set_upper_bound(tt,bd_val)
        push!(list_art_ub_refs,tt)
        println(io,linobj_expr.terms[tt]," * ",tt,"  New UB: ",bd_val)
        set_lower_bound(tt,-bd_val)
        push!(list_art_lb_refs,tt)
        println(io,linobj_expr.terms[tt]," * ",tt,"  New LB: ",-bd_val)
    end
    model_info["list_art_ub_refs"]=list_art_ub_refs
    model_info["list_art_lb_refs"]=list_art_lb_refs
end
function test_artificial_bds(model_info)
    ### "As precondition, assume that: "
    ### " 1) the expression 'linobj_expr' is set"
    ### " 2) the model is solved with dual values for artificial bounds computed"
    test_passes=true
    linobj_expr = objective_function(model_info["model"], AffExpr)
    list_art_ub_refs=model_info["list_art_ub_refs"]
    list_art_lb_refs=model_info["list_art_lb_refs"]
    for tt in list_art_ub_refs
        @assert JuMP.has_upper_bound(tt)
        ub_dual_val = JuMP.dual(UpperBoundRef(tt))
        if abs(ub_dual_val) > 1e-6 && !( (occursin("p", JuMP.name(tt)) || occursin("q", JuMP.name(tt))) && JuMP.upper_bound(tt) >= 1  )
            println("FLAGGING: ub dual of variable ",tt," is ",ub_dual_val, " var value is: ",JuMP.value(tt))
            test_passes=false
            JuMP.set_upper_bound(tt,10*JuMP.upper_bound(tt))
        end
    end
    for tt in list_art_lb_refs
        @assert JuMP.has_lower_bound(tt)
        lb_dual_val = JuMP.dual(LowerBoundRef(tt))
        if abs(lb_dual_val) > 1e-6 && !( (occursin("p", JuMP.name(tt)) || occursin("q", JuMP.name(tt))) && JuMP.lower_bound(tt) <= -1  )
            println("FLAGGING: lb dual of variable ",tt," is ",lb_dual_val, " var value is: ",JuMP.value(tt))
            test_passes=false
            JuMP.set_lower_bound(tt,10*JuMP.lower_bound(tt))
        end
    end
    return test_passes
end

function gatherPSDConInfo(model_info::Dict{String,Any})
    model_info["psd_info"] = gatherPSDConInfo(model_info["model"])
end

function gatherPSDConInfo(model::JuMP.Model)
    con_types=list_of_constraint_types(model)
    n_con_types=length(con_types)
    PSD = Dict{Tuple{Int64,Int64},Dict{String,Any}}()
    psd_con_type_ids = filter( cc->(con_types[cc][2]==MathOptInterface.PositiveSemidefiniteConeTriangle), 1:n_con_types)
    for cc in psd_con_type_ids
        psd_con = all_constraints(model, con_types[cc][1], con_types[cc][2]) 
        n_con = length(psd_con)
        for nn in 1:n_con
            PSD[cc,nn] = Dict{String,Any}()
            PSD[cc,nn]["cref"] = psd_con[nn]
            PSD[cc,nn]["expr"] = constraint_object(psd_con[nn]).func
            PSD[cc,nn]["vec_len"] = length(PSD[cc,nn]["expr"])
        end
    end
    @expression(model, psd_expr[kk in keys(PSD), mm=1:PSD[kk]["vec_len"]], PSD[kk]["expr"][mm] )
    for kk in keys(PSD)
            PSD[kk]["model"] = model
            PSD[kk]["cuts"] = Dict{ConstraintRef,Dict{String,Any}}() ### "Will be productive later"
            PSD[kk]["new_cuts"] = Dict{ConstraintRef,Dict{String,Any}}()
            vec_len = PSD[kk]["vec_len"] 
            PSD[kk]["expr_val"] = zeros(vec_len)
            PSD[kk]["dual_val"] = zeros(vec_len)
            PSD[kk]["expr_val_ctr"] = zeros(vec_len)
            PSD[kk]["old_expr_val_ctr"] = zeros(vec_len)
            PSD[kk]["proj_expr_val"] = zeros(vec_len)
            PSD[kk]["orth_expr_val"] = zeros(vec_len)
            PSD[kk]["orth_norm"] = 0.0
            PSD[kk]["C"] = zeros(vec_len) ### Dual solution
            PSD[kk]["C_norm"] = 0
            PSD[kk]["prim_res"] = zeros(vec_len)
            PSD[kk]["prim_res_norm"] = 0.0
            PSD[kk]["dual_res"] = zeros(vec_len)
            PSD[kk]["dual_res_norm"] = 0.0
            PSD[kk]["prox_t"] = 1
            PSD[kk]["scale_factor"] = 1.0
            PSD[kk]["sg"] = zeros(vec_len)
            PSD[kk]["ij_pairs"] = Array{Tuple{Int64,Int64},1}(undef, vec_len)
            PSD[kk]["ii"] = zeros(Int64,vec_len)
            PSD[kk]["jj"] = zeros(Int64,vec_len)
            PSD[kk]["diag_ids"] = Dict{Int64,Int64}()
            PSD[kk]["min_eigval"] = 0.0
            PSD[kk]["ssc_val"] = 0.0
            PSD[kk]["ip"] = ones(vec_len) ### "coefficients to aid in computing Frobenius inner product"
            PSD[kk]["is_off_diag"] = zeros(vec_len) ### "coefficients to aid in computing Frobenius inner product"
	        jj,ii=1,1
            for mm in 1:vec_len
                PSD[kk]["ij_pairs"][mm]=(ii,jj)
                PSD[kk]["ii"][mm]=ii
                PSD[kk]["jj"][mm]=jj
                if ii==jj
                    PSD[kk]["diag_ids"][jj] = mm
                    PSD[kk]["ip"][mm] = 1
                    PSD[kk]["is_off_diag"][mm] = 0
                    jj += 1
                    ii = 1
                else
                    PSD[kk]["ip"][mm] = 2
                    PSD[kk]["is_off_diag"][mm] = 1
                    ii += 1
                end
            end
            PSD[kk]["ncols"] = PSD[kk]["jj"][ PSD[kk]["vec_len"] ]
            PSD[kk]["psd_mat"] = zeros( PSD[kk]["ncols"], PSD[kk]["ncols"] )
            PSD[kk]["diag_els"] = filter(mmm->(PSD[kk]["is_off_diag"][mmm] == 0),1:PSD[kk]["vec_len"])
            PSD[kk]["off_diag_els"] = filter(mmm->(PSD[kk]["is_off_diag"][mmm] == 1),1:PSD[kk]["vec_len"])
            PSD[kk]["quad_terms"] = AffExpr(0.0)
            PSD[kk]["quad_term_vals"] = 0.0
            PSD[kk]["Lagr_terms"] = AffExpr(0.0)
            PSD[kk]["Lagr_term_vals"] = 0.0
    end
    return PSD
end

function add_psd_initial_cuts(model_info; bdmag=1e3, io=Base.stdout)
    model=model_info["model"]
    psd_expr = model[:psd_expr]
    PSD = model_info["psd_info"]
    JuMP.@constraint( model, psd_lbs[kk in keys(PSD), mm in 1:PSD[kk]["vec_len"]], psd_expr[kk,mm] >= -bdmag*PSD[kk]["is_off_diag"][mm] )
    JuMP.@constraint( model, psd_ubs[kk in keys(PSD), mm in 1:PSD[kk]["vec_len"]], psd_expr[kk,mm] <= bdmag )

    #JuMP.@constraint( model, psd_diag_lbs[kk in keys(PSD), mm in PSD[kk]["diag_els"]], psd_expr[kk,mm] >= 0.0 )
    #JuMP.@constraint( model, psd_diag_ubs[kk in keys(PSD), mm in PSD[kk]["diag_els"]], psd_expr[kk,mm] <= bdmag )
    #JuMP.@constraint( model, psd_ub[kk in keys(PSD), mm in 1:PSD[kk]["vec_len"]], sum( psd_expr[kk,mm] for mm in 1:PSD[kk]["vec_len"]) <= bdmag )
    #JuMP.@constraint( model, psd_lb[kk in keys(PSD), mm in 1:PSD[kk]["vec_len"]], sum( psd_expr[kk,mm] for mm in 1:PSD[kk]["vec_len"]) >= -bdmag )
    #JuMP.@constraint( model, psd_diag_ubs[kk in keys(PSD), mm in PSD[kk]["diag_els"]], psd_expr[kk,mm] <= bdmag )
#=
    JuMP.@constraint( psd_info["cp_model"], psd_diag_lbs[kk in keys(PSD), mm in PSD[kk]["diag_els"]], psd_expr[kk,mm] >= 0.0 )
    JuMP.@constraint( psd_info["cp_model"], psd_diag_ubs[kk in keys(PSD), mm in PSD[kk]["diag_els"]], psd_expr[kk,mm] <= bdmag )

    JuMP.@constraint( psd_info["cp_model"], psd_off_diag_con1[kk in keys(PSD), mm in PSD[kk]["off_diag_els"]], 
              psd_expr[kk, PSD[kk]["diag_ids"][ PSD[kk]["ij_pairs"][mm][1] ]  ] + 2*psd_expr[kk,mm] 
            + psd_expr[kk, PSD[kk]["diag_ids"][ PSD[kk]["ij_pairs"][mm][2] ]  ] >= 0.0 )
    JuMP.@constraint( psd_info["cp_model"], psd_off_diag_con2[kk in keys(PSD), mm in PSD[kk]["off_diag_els"]], 
              psd_expr[kk, PSD[kk]["diag_ids"][ PSD[kk]["ij_pairs"][mm][1] ]  ] - 2*psd_expr[kk,mm] 
            + psd_expr[kk, PSD[kk]["diag_ids"][ PSD[kk]["ij_pairs"][mm][2] ]  ] >= 0.0 )
=#
end

function removePSD_Constraints(PSD) 
    for kk in keys(PSD)
        delete(PSD[kk]["model"],PSD[kk]["cref"])
    end
end

function conditionallyUpdateProxCenter(model_info)
    PSD=model_info["psd_info"]
    mp_obj_val = model_info["lin_objval"] 
    obj_val_ctr = model_info["lin_objval_ctr"] + 100*sum( PSD[kk]["eigval_ctr"] for kk in keys(PSD) ) 
    obj_val =     model_info["lin_objval"]     + 100*sum( PSD[kk]["min_eigval"]     for kk in keys(PSD) ) 
    if (obj_val - obj_val_ctr) >= 0.1*(mp_obj_val - obj_val_ctr) 
        model_info["lin_objval_ctr"] = model_info["lin_objval"]
        for kk in keys(PSD)
            PSD[kk]["expr_val_ctr"][:] = PSD[kk]["expr_val"][:] 
            PSD[kk]["eigval_ctr"] = PSD[kk]["min_eigval"]
        end
    end
end

function aggregate_cuts(model_info)
    ###TODO: Aggregate the set of new cuts into an aggregate
    model = model_info["model"] 
    psd_expr = model[:psd_expr]
    PSD=model_info["psd_info"]
    for kk in keys(PSD)
        if length(PSD[kk]["cuts"]) > 1
            C=zeros(PSD[kk]["vec_len"])
            dual_sum=0
            for cc in keys(PSD[kk]["cuts"])
                dual_sum += PSD[kk]["cuts"][cc]["dual_val"]
                C[:] += PSD[kk]["cuts"][cc]["dual_val"]*PSD[kk]["cuts"][cc]["C"][:]
                JuMP.delete(model,cc)
            end
            empty!(PSD[kk]["cuts"])
            if dual_sum > 1e-6
                C[:] /= dual_sum
                agg_ref = JuMP.@constraint(model, 
                    sum( PSD[kk]["ip"][nn]*C[nn]*psd_expr[kk,nn] for nn in 1:PSD[kk]["vec_len"]) <= 0 )
                PSD[kk]["cuts"][agg_ref]=Dict{String,Any}("C"=>C)
            end
        end
    end
end

function delete_inactive_cuts(model_info; tol=1e-6)
    ###TODO: Aggregate the set of new cuts into an aggregate
    model = model_info["model"] 
    psd_expr = model[:psd_expr]
    PSD=model_info["psd_info"]
    n_del = 0
    for kk in keys(PSD)
        cuts = keys(PSD[kk]["cuts"])
        for cc in cuts 
            if PSD[kk]["cuts"][cc]["dual_val"] < 1e-6
                JuMP.delete(model,cc)
                delete!(PSD[kk]["cuts"],cc)
                n_del += 1
            end
        end
    end
    println("\t\tDeleting $n_del inactive cuts.")
end



###Input is symmetric matrix in triangular form
function computePSDMat(PSD, tri_mat)
    for nn=1:PSD["vec_len"]
        ii,jj=PSD["ii"][nn],PSD["jj"][nn]
	    PSD["psd_mat"][ii,jj] = tri_mat[nn]
        if ii != jj
	        PSD["psd_mat"][jj,ii] = PSD["psd_mat"][ii,jj]
        end
    end
end

### "Precondition: PSD[kk]['expr_val'] set via a recent solve"
function PSDProjections(model_info; sg_only=false)
    model_info["total_sum_neg_eigs"] = 0
    model_info["orth_norm"] = 0
    model = model_info["model"]
    psd_expr = model[:psd_expr]
    PSD = model_info["psd_info"]
    for kk in keys(PSD)
        computePSDMat(PSD[kk], PSD[kk]["expr_val"])
        E = eigen(PSD[kk]["psd_mat"])
        eig_vals,eig_vecs = E
        n_eigs = length(eig_vals)
        neg_eigs = filter(mmm->(eig_vals[mmm] < -1e-8), 1:n_eigs)
        PSD[kk]["neg_eigs_sum"] = 0
        if length(neg_eigs) > 0
            PSD[kk]["neg_eigs_sum"] = sum( eig_vals[mm] for mm in neg_eigs )
            model_info["total_sum_neg_eigs"] += PSD[kk]["neg_eigs_sum"]
        end
        PSD[kk]["min_eigval"],min_idx = findmin(eig_vals)
        for nn=1:PSD[kk]["vec_len"]
            ii,jj=PSD[kk]["ii"][nn],PSD[kk]["jj"][nn]
	        PSD[kk]["sg"][nn] = eig_vecs[ii,min_idx]*eig_vecs[jj,min_idx]  
        end
        PSD[kk]["proj_expr_val"][:] = PSD[kk]["expr_val"][:]
        PSD[kk]["orth_expr_val"][:] .= 0.0
        PSD[kk]["orth_norm"] = 0.0
        if length(neg_eigs) > 0
            for nn=1:PSD[kk]["vec_len"]
                ii,jj=PSD[kk]["ii"][nn],PSD[kk]["jj"][nn]
                PSD[kk]["orth_expr_val"][nn] = sum( eig_vals[mm]*eig_vecs[ii,mm]*eig_vecs[jj,mm] for mm in neg_eigs)
            end
            PSD[kk]["proj_expr_val"][:] = PSD[kk]["expr_val"][:] - PSD[kk]["orth_expr_val"][:]
            PSD[kk]["orth_norm"] = norm(PSD[kk]["orth_expr_val"][:])
            model_info["orth_norm"] += PSD[kk]["orth_norm"]^2
        end
    end
    model_info["orth_norm"] = sqrt(model_info["orth_norm"])
end

function ADMMProjections(model_info; validate=false, io=Base.stdout)
    model_info["total_sum_neg_eigs"] = 0
    model = model_info["model"]
    psd_expr = model[:psd_expr]
    prox_sign = model_info["prox_sign"]
    PSD = model_info["psd_info"]
    for kk in keys(PSD)
        rho_kk = PSD[kk]["scale_factor"]
        PSD[kk]["old_expr_val_ctr"][:] = PSD[kk]["expr_val_ctr"][:]
        PSD[kk]["expr_val_ctr"][:] = PSD[kk]["expr_val"][:] + PSD[kk]["C"][:]
        computePSDMat(PSD[kk], PSD[kk]["expr_val_ctr"])
        E = eigen(PSD[kk]["psd_mat"])
        eig_vals,eig_vecs = E

        n_eigs = length(eig_vals)
        neg_eigs = filter(mmm->(eig_vals[mmm] < -1e-8), 1:n_eigs)
        PSD[kk]["neg_eigs_sum"] = 0
        if length(neg_eigs) > 0
            PSD[kk]["neg_eigs_sum"] = sum( eig_vals[mm] for mm in neg_eigs )
            model_info["total_sum_neg_eigs"] += PSD[kk]["neg_eigs_sum"]
        end
        println(io,"eigenval_$kk: ", eig_vals)
        PSD[kk]["min_eigval"],min_eigval_idx = findmin(eig_vals)
        if length(neg_eigs) > 0
            for nn=1:PSD[kk]["vec_len"]
                ii,jj=PSD[kk]["ii"][nn],PSD[kk]["jj"][nn]
                orth_proj = sum( eig_vals[mm]*eig_vecs[ii,mm]*eig_vecs[jj,mm] for mm in neg_eigs)
                PSD[kk]["expr_val_ctr"][nn] = PSD[kk]["expr_val"][nn] + PSD[kk]["C"][nn] - orth_proj
            end
        else
            PSD[kk]["expr_val_ctr"][:] = PSD[kk]["expr_val"][:] + PSD[kk]["C"][:]
        end
        PSD[kk]["prim_res"][:] = PSD[kk]["expr_val"][:] - PSD[kk]["expr_val_ctr"][:]
        PSD[kk]["dual_res"][:] = (PSD[kk]["expr_val_ctr"][:] - PSD[kk]["old_expr_val_ctr"][:])
        PSD[kk]["C"][:] = PSD[kk]["C"][:] + PSD[kk]["expr_val"][:] - PSD[kk]["expr_val_ctr"][:]
        PSD[kk]["C_norm"] = 0.0
        for nn=1:PSD[kk]["vec_len"]
            PSD[kk]["C_norm"] += PSD[kk]["ip"][nn]*PSD[kk]["C"][nn]*PSD[kk]["C"][nn]
        end
        PSD[kk]["prim_res_norm"] = sqrt(sum( PSD[kk]["ip"][nn]*PSD[kk]["prim_res"][nn]^2 for nn=1:PSD[kk]["vec_len"]))
        PSD[kk]["dual_res_norm"] = sqrt(sum( PSD[kk]["ip"][nn]*PSD[kk]["dual_res"][nn]^2 for nn=1:PSD[kk]["vec_len"]))
        PSD[kk]["<C,X>"]= sum( PSD[kk]["ip"][nn]*PSD[kk]["C"][nn]*PSD[kk]["expr_val"][nn] for nn=1:PSD[kk]["vec_len"])
        if validate
            computePSDMat(PSD[kk], PSD[kk]["C"])
            E = eigen(PSD[kk]["psd_mat"])
            eig_vals,eig_vecs = E
            PSD[kk]["min_eigval_C"],min_idx = findmax(eig_vals)
            PSD[kk]["min_eigval_C"]=round(PSD[kk]["min_eigval_C"];digits=4)
            PSD[kk]["<C,Z>"]= round(sum( PSD[kk]["ip"][nn]*PSD[kk]["C"][nn]*PSD[kk]["expr_val_ctr"][nn] for nn=1:PSD[kk]["vec_len"]);digits=4)
            #println("$kk:\t\tmineigvalC=",PSD[kk]["min_eigval_C"],"\t\t<C,X>=",PSD[kk]["<C,X>"],"\t\t<C,Z>=",PSD[kk]["<C,Z>"],"\t\t|C|=",PSD[kk]["C_norm"])
        end
    end
    model_info["<C,X>"] = sum(PSD[kk]["<C,X>"] for kk in keys(PSD))
    if validate
        model_info["<C,Z>"] = sum(PSD[kk]["<C,Z>"] for kk in keys(PSD))
    end
end

function solveSP(model_info; fix_x=false, record_x=false, compute_projection=true, compute_psd_dual=false, io=devnull)
    model = model_info["model"]
    branch_ids = model_info["branch_ids"]
    PSD=model_info["psd_info"] 
    psd_expr = model[:psd_expr]
    unfix_vars(model,branch_ids)
    if fix_x
        if haskey(model_info, "x_soln")
            for l in keys(model_info["x_soln"])
                x_var = variable_by_name(model,"x[$l]_1")
                fix(x_var, max(min(model_info["x_soln"][l],1),0); force=true)
            end
        end
    end
            
    JuMP.optimize!(model)
    model_info["opt_val"]=JuMP.objective_value(model)
    model_info["solve_status"]=JuMP.termination_status(model)
    if record_x
        model_info["x_soln_str"]=""
        for l in model_info["branch_ids"]
            x_var = variable_by_name(model_info["model"],"x[$l]_1")
            x_val = JuMP.value(x_var)
            if x_val > 1.0-1.0e-8
	            x_val = 1
                model_info["x_soln_str"] = string(model_info["x_soln_str"]," $l")
            elseif x_val < 1.0e-8
	            x_val = 0
            end
            model_info["x_soln"][l] = x_val
        end
    end
    for kk in keys(PSD)
        for nn=1:PSD[kk]["vec_len"]
            PSD[kk]["expr_val"][nn] = JuMP.value(psd_expr[kk,nn])
        end
        if compute_psd_dual
            PSD[kk]["dual_val"][:] = JuMP.dual.(PSD[kk]["cref"])[:]
        end
    end
    if compute_projection
        PSDProjections(model_info)
    end
    if fix_x
        unfix_vars(model,branch_ids)
    end
end #end of function

### "Precondition: Make sure that the relevant data structure, be it 'sg', 'dual_val', or 'orth_expr_val' has been computed"
function add_cuts(model_info::Dict{String,Any}, PSD::Dict{Tuple{Int64,Int64},Dict{String,Any}}; cut_type::String="sg", tol=1e-5)
    model = model_info["model"]
    psd_expr = model[:psd_expr]
    for kk in keys(PSD)
        if cut_type == "sg"  
            JuMP.@constraint(model, sum( PSD[kk]["ip"][nn]*PSD[kk][cut_type][nn]*psd_expr[kk,nn] for nn in 1:PSD[kk]["vec_len"]) >= 0 )
        elseif cut_type == "dual_val"
            vec_norm = norm(PSD[kk][cut_type][:])
            if vec_norm > tol
                JuMP.@constraint(model, (1/vec_norm)*sum( PSD[kk]["ip"][nn]*PSD[kk][cut_type][nn]*psd_expr[kk,nn] for nn in 1:PSD[kk]["vec_len"]) >= 0 )
            end
        elseif cut_type == "orth_expr_val"
            if PSD[kk]["orth_norm"] > tol
                JuMP.@constraint(model, 
                    (1/PSD[kk]["orth_norm"])*sum( PSD[kk]["ip"][nn]*PSD[kk][cut_type][nn]*psd_expr[kk,nn] for nn in 1:PSD[kk]["vec_len"]) <= 0 
                )
            end
        else
            println(Base.stderr,"add_cuts(): cut_type=",cut_type," is unrecognized.")
        end
    end
end

function fixPSDCtr(model_info::Dict{String,Any}; psd_key="expr_val_ctr")
    model = model_info["model"]
    PSD=model_info["psd_info"]
    psd_expr = model[:psd_expr]

    for kk in keys(PSD)
        for nn=1:PSD[kk]["vec_len"]
            if typeof(psd_expr[kk,nn])==VariableRef
                fix(psd_expr[kk,nn], PSD[kk]["expr_val_ctr"][nn]; force=true)
            elseif typeof(psd_expr[kk,nn])==GenericAffExpr{Float64,VariableRef}
                n_terms = length(psd_expr[kk,nn].terms)
                if n_terms == 1
                    JuMP.@constraint(model, psd_expr[kk,nn] - PSD[kk]["expr_val_ctr"][nn] == 0)
                elseif n_terms > 1
                    println(Base.stderr,"Cannot fix ",psd_expr[kk,nn], ", which has $n_terms terms")
                end
#=
                for tt in keys(psd_expr[kk,nn].terms)
                    fix(tt, PSD[kk]["expr_val_ctr"][nn]/(psd_expr[kk,nn].terms[tt]); force=true)
                end
=#
            else
                ### TODO
                println(Base.stderr,"Cannot fix psd_expr[$kk,$nn], which is of type ",typeof(psd_expr[kk,nn]))
                #=
                for tt in keys(psd_expr[kk,nn].terms)
                    fix(psd_expr[kk,nn], PSD[kk]["expr_val_ctr"]); force=true)
                    PSD[kk]["expr_val"][nn] += psd_expr[kk,nn].terms[tt]*JuMP.callback_value(cb_data,tt)
                end
                =#
            end
        end
    end
end

function unfixPSDCtr(model_info::Dict{String,Any})
    model = model_info["model"]
    PSD=model_info["psd_info"]
    psd_expr = model[:psd_expr]

    for kk in keys(PSD)
        for nn=1:PSD[kk]["vec_len"]
            if typeof(psd_expr[kk,nn])==VariableRef
                unfix(psd_expr[kk,nn])
            elseif typeof(psd_expr[kk,nn])==GenericAffExpr{Float64,VariableRef}
                for tt in keys(psd_expr[kk,nn].terms)
                    unfix(tt)
                end
            end
        end
    end
end

function add_C_cuts(model_info; delete_inactive=false, tol=1e-6)
    model = model_info["model"] 
    psd_expr = model[:psd_expr]
    PSD=model_info["psd_info"]
    
    if delete_inactive
        delete_inactive_cuts(model_info; tol=1e-6)
    end
    for kk in keys(PSD)
        if PSD[kk]["<C,X>"] >= tol
            cref = JuMP.@constraint(model_info["model"], 
                sum( PSD[kk]["ip"][nn]*PSD[kk]["C"][nn]*psd_expr[kk,nn] for nn in 1:PSD[kk]["vec_len"]) <= 0 )
            PSD[kk]["cuts"][cref]=Dict{String,Any}("C"=>copy(PSD[kk]["C"]))
        end
    end
end

### "THIS FUNCTION IS NOT DEBUGGED"
### "Precondition: C and <C,X> keys of PSD[kk] are computed, and dual values exists for existing C_cut references"
function add_or_modify_C_cuts(model_info; tol=1e-6)
    model = model_info["model"] 
    psd_expr = model[:psd_expr]
    PSD=model_info["psd_info"]
    for kk in keys(PSD)
        if PSD[kk]["<C,X>"] >= tol
            if !haskey(PSD[kk],"C_cut") 
                PSD[kk]["C_cut"]=Dict{String,Any}()
                PSD[kk]["C_cut"]["ref"]=JuMP.@constraint(model_info["model"], 
                    sum( PSD[kk]["ip"][nn]*PSD[kk]["C"][nn]*psd_expr[kk,nn] for nn in 1:PSD[kk]["vec_len"]) <= 0 )
                PSD[kk]["C_cut"]["coeff"]=Dict{VariableRef,Float64}()
                con_expr = constraint_object(PSD[kk]["C_cut"]["ref"]).func 
                for vv in keys(con_expr.terms)
                    PSD[kk]["C_cut"]["coeff"][vv]=con_expr.terms[vv]
                end
            else
                if !haskey(PSD[kk]["C_cut"], "agg_ref")
                    PSD[kk]["C_cut"]["agg_ref"] = PSD[kk]["C_cut"]["ref"]
                else
                end
                
                if PSD[kk]["C_cut"]["dual_val"] >= tol
                    for tt in keys(PSD[kk]["C_cut"]["coeff"])
                        PSD[kk]["C_cut"]["coeff"][tt] *= PSD[kk]["C_cut"]["dual_val"]
                    end
                else
                    for tt in keys(PSD[kk]["C_cut"]["coeff"])
                        PSD[kk]["C_cut"]["coeff"][tt] = 0.0
                    end
                end
                for nn=1:PSD[kk]["vec_len"]
                    if typeof(psd_expr[kk,nn])==VariableRef
                        if haskey(PSD[kk]["C_cut"]["coeff"],psd_expr[kk,nn])
                            PSD[kk]["C_cut"]["coeff"][psd_expr[kk,nn]] += PSD[kk]["ip"][nn]*PSD[kk]["C"][nn]
                        else
                            PSD[kk]["C_cut"]["coeff"][psd_expr[kk,nn]] = PSD[kk]["ip"][nn]*PSD[kk]["C"][nn]
                        end
                    else
                        @assert typeof(psd_expr[kk,nn])==GenericAffExpr{Float64,VariableRef}
                        for tt in keys(psd_expr[kk,nn].terms)
                            if haskey(PSD[kk]["C_cut"]["coeff"],tt)
                                PSD[kk]["C_cut"]["coeff"][tt] += PSD[kk]["ip"][nn]*(psd_expr[kk,nn].terms[tt])*PSD[kk]["C"][nn]
                            else
                                PSD[kk]["C_cut"]["coeff"][tt] = PSD[kk]["ip"][nn]*(psd_expr[kk,nn].terms[tt])*PSD[kk]["C"][nn]
                            end
                        end
                    end
                    for tt in keys(PSD[kk]["C_cut"]["coeff"])
	                    JuMP.set_normalized_coefficient(PSD[kk]["C_cut"]["ref"],tt,PSD[kk]["C_cut"]["coeff"][tt])
                    end
                end
            end
        end
    end
end