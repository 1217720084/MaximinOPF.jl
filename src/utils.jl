using JuMP, MathOptInterface
using PowerModels
#
function getBranchIds(pm_data)
    branch_ids=Int64[]
    for ll in keys(pm_data["branch"])
        push!(branch_ids,parse(Int64,ll))
    end
    sort!(branch_ids)
    return branch_ids
end

function ConvertModelToDualizableForm(model::JuMP.Model)
    soc_model = MOI.Utilities.Model{Float64}()
    soc_bridged_model = MOI.Bridges.Constraint.QuadtoSOC{Float64}(soc_model)
    MOI.copy_to(soc_bridged_model,backend(model))    

    dualizable_model = JuMP.Model()
    bridged_model = MOI.Bridges.Constraint.Square{Float64}(backend(dualizable_model))
    MOI.copy_to(bridged_model,soc_model)    
	return dualizable_model
end

function removeRedundantConstraints(pm::AbstractPowerModel)
    # "So far, do nothing"
end
function removeRedundantConstraints(pm::AbstractConicModels)
    con_types=list_of_constraint_types(pm.model)
    n_con_types=length(con_types)
    for cc=1:n_con_types
        if con_types[cc][2]==MathOptInterface.RotatedSecondOrderCone
	        ### These constraints are presumably associated with defining the quadratic cost function for the OPF and are usually not needed here.
	        rsoc_con = all_constraints(pm.model, con_types[cc][1], con_types[cc][2]) 
	        n_rsoc_con = length(rsoc_con)
	        for nn=1:n_rsoc_con
		        rsoc_expr = constraint_object(rsoc_con[nn]).func 
		        n_vars=length( rsoc_expr ) 
		        if n_vars == 3  ### "This condition is necessary for the RSOC to have the nonproductive constraint in question"
                    io2=IOBuffer()
                    print(io2,rsoc_expr[2])
                    io3=IOBuffer()
                    print(io3,rsoc_expr[3])
                    if occursin("pg", String(take!(io2))) && occursin("pg", String(take!(io3)))
                        #println("Removing constraint: ",rsoc_con[nn])
		                JuMP.delete(pm.model,rsoc_con[nn])
                    end
                end
	        end
	    end
    end
end

function replaceThermalLineLimits(pm::AbstractPowerModel)
    con_types=list_of_constraint_types(pm.model)
    n_con_types=length(con_types)
    for cc=1:n_con_types
        correct_con_type = (con_types[cc][1]==GenericQuadExpr{Float64,VariableRef} && con_types[cc][2]==MathOptInterface.LessThan{Float64}) 
        if correct_con_type
	        for con in all_constraints(pm.model, con_types[cc][1], con_types[cc][2]) 
		        expr = constraint_object(con).func 
                io_con=IOBuffer()
                print(io_con,expr)
                con_str=String(take!(io_con))
                if occursin("p[(", con_str) && occursin("q[(", con_str)
                    #println("Removing constraint: ",con)
		            JuMP.delete(pm.model,con)
                end
	        end
	    end
    end
    pm_type = typeof(pm)
    for l in ids(pm,pm.cnw,:branch)
        branch = ref(pm, pm.cnw, :branch, l)
        if haskey(branch, "rate_a")
            f_bus,t_bus = branch["f_bus"],branch["t_bus"]
            f_idx,t_idx = (l, f_bus, t_bus),(l, t_bus, f_bus)
            #re-add constraints using auxiliary variable proxies for power flow variables
            pf_m = var(pm, pm.cnw, :pt_br)[f_idx,0]
            pf_p = var(pm, pm.cnw, :pt_br)[f_idx,1]
            pt_m = var(pm, pm.cnw, :pt_br)[t_idx,0]
            pt_p = var(pm, pm.cnw, :pt_br)[t_idx,1]
            qf_m = var(pm, pm.cnw, :qt_br)[f_idx,0]
            qf_p = var(pm, pm.cnw, :qt_br)[f_idx,1]
            qt_m = var(pm, pm.cnw, :qt_br)[t_idx,0]
            qt_p = var(pm, pm.cnw, :qt_br)[t_idx,1]
            cref_f=JuMP.@constraint(pm.model, (pf_p-pf_m)^2 + (qf_p-qf_m)^2 <= branch["rate_a"]^2)
            JuMP.set_name(cref_f,string("th_l_lim_f[",f_idx,"]"))
            #println("Replacing the 'from' thermal line limit with: ",cref_f)
            cref_t=JuMP.@constraint(pm.model, (pt_p-pt_m)^2 + (qt_p-qt_m)^2 <= branch["rate_a"]^2)
            JuMP.set_name(cref_t,string("th_l_lim_t[",t_idx,"]"))
            #println("Replacing the 'to' thermal line limit with: ",cref_t)
        end
    end
end
function replaceThermalLineLimits(pm::AbstractConicModels)
    con_types=list_of_constraint_types(pm.model)
    n_con_types=length(con_types)
    for cc=1:n_con_types
        correct_con_type = con_types[cc][2]==MathOptInterface.SecondOrderCone
        if correct_con_type
	        for con in all_constraints(pm.model, con_types[cc][1], con_types[cc][2]) 
		        expr = constraint_object(con).func 
                io_con=IOBuffer()
                print(io_con,expr)
                con_str=String(take!(io_con))
                if occursin("p[(", con_str) && occursin("q[(", con_str)
                    #println("Removing constraint: ",con)
		            JuMP.delete(pm.model,con)
                end
	        end
	    end
    end
    for l in ids(pm,pm.cnw,:branch)
        branch = ref(pm, pm.cnw, :branch, l)
        if haskey(branch, "rate_a")
            f_bus,t_bus = branch["f_bus"],branch["t_bus"]
            f_idx,t_idx = (l, f_bus, t_bus),(l, t_bus, f_bus)
            #re-add constraints using auxiliary variable proxies for power flow variables
            pf_m = var(pm, pm.cnw, :pt_br)[f_idx,0]
            pf_p = var(pm, pm.cnw, :pt_br)[f_idx,1]
            pt_m = var(pm, pm.cnw, :pt_br)[t_idx,0]
            pt_p = var(pm, pm.cnw, :pt_br)[t_idx,1]
            qf_m = var(pm, pm.cnw, :qt_br)[f_idx,0]
            qf_p = var(pm, pm.cnw, :qt_br)[f_idx,1]
            qt_m = var(pm, pm.cnw, :qt_br)[t_idx,0]
            qt_p = var(pm, pm.cnw, :qt_br)[t_idx,1]
            cref_f=JuMP.@constraint(pm.model, [branch["rate_a"], pf_p-pf_m, qf_p-qf_m] in JuMP.SecondOrderCone())
            JuMP.set_name(cref_f,string("th_l_lim_f[",f_idx,"]"))
            #println("Replacing the 'from' thermal line limit with: ",cref_f)
            cref_t=JuMP.@constraint(pm.model, [branch["rate_a"], pt_p-pt_m, qt_p-qt_m] in JuMP.SecondOrderCone())
            JuMP.set_name(cref_t,string("th_l_lim_t[",t_idx,"]"))
            #println("Replacing the 'to' thermal line limit with: ",cref_t)
        end
    end
end

# "Precondition: replaceThermalLineLimits() has been called"
function removeThermalLineLimits(pm::AbstractPowerModel)
    for l in ids(pm,pm.cnw,:branch)
        branch = ref(pm, pm.cnw, :branch, l)
        if haskey(branch, "rate_a")
            f_bus,t_bus = branch["f_bus"],branch["t_bus"]
            f_idx,t_idx = (l, f_bus, t_bus),(l, t_bus, f_bus)
            JuMP.delete(pm.model,JuMP.constraint_by_name(pm.model,string("th_l_lim_f[",f_idx,"]")))
            JuMP.delete(pm.model,JuMP.constraint_by_name(pm.model,string("th_l_lim_t[",t_idx,"]")))
        end
    end
end


function getMaxShedding(pm_data)
    maxShed=0.0
    for ll in keys(pm_data["load"])
        maxShed += abs(pm_data["load"][ll]["pd"]) + abs(pm_data["load"][ll]["qd"])
    end
    for gg in keys(pm_data["gen"])
        maxShed += max(pm_data["gen"][gg]["pmin"],0) + max(pm_data["gen"][gg]["qmin"],0)
    end
    return maxShed 
end

function convertSOCtoPSD(model::JuMP.Model)
    #BRIDGE SOC CONSTRAINTS
    model_rsoc_moi = MOI.Utilities.Model{Float64}()
    rsoc_bridged_model = MOI.Bridges.Constraint.SOCtoPSD{Float64}(model_rsoc_moi)
    MOI.copy_to(rsoc_bridged_model,backend(model))

    model_psd_moi = MOI.Utilities.Model{Float64}()
    psd_bridged_model = MOI.Bridges.Constraint.RSOCtoPSD{Float64}(model_psd_moi)
    MOI.copy_to(psd_bridged_model,model_rsoc_moi)
    model_psd = JuMP.Model()
    MOI.copy_to(backend(model_psd),model_psd_moi)
    return model_psd
end

function unfix_vars(model,branch_ids)
    for l in branch_ids
        if is_fixed(variable_by_name(model,"x[$l]_1"))
            unfix(variable_by_name(model,"x[$l]_1"))
        end
        set_lower_bound(variable_by_name(model,"x[$l]_1"),0)
        set_upper_bound(variable_by_name(model,"x[$l]_1"),1)
    end
end

function fix_integer_vals(model_info)
    relax_integrality(model_info)
    for l in model_info["branch_ids"]
        if is_fixed(variable_by_name(model_info["model"],"x[$l]_1"))
            unfix(variable_by_name(model_info["model"],"x[$l]_1"))
        end
        fix(variable_by_name(model_info["model"],"x[$l]_1"), model_info["x_soln"][l]; force=true)
    end
end

function relax_integrality(model_dict)
    for l in model_dict["branch_ids"]
	    if JuMP.is_fixed(variable_by_name(model_dict["model"],"x[$l]_1"))
            unfix(variable_by_name(model_dict["model"],"x[$l]_1"))
        end
	    if JuMP.is_integer(variable_by_name(model_dict["model"],"x[$l]_1"))
            JuMP.unset_integer(variable_by_name(model_dict["model"],"x[$l]_1"))
            JuMP.set_lower_bound(variable_by_name(model_dict["model"],"x[$l]_1"),0)
            JuMP.set_upper_bound(variable_by_name(model_dict["model"],"x[$l]_1"),1)
	    else
            JuMP.set_lower_bound(variable_by_name(model_dict["model"],"x[$l]_1"),0)
            JuMP.set_upper_bound(variable_by_name(model_dict["model"],"x[$l]_1"),1)
	    end
    end
end

### "Copied from current master version of JuMP, as of 7 Feb 2020. At some point, we can use the JuMP stable version."
function JuMP_write_to_file(
    model::Model,
    filename::String;
    format::MOI.FileFormats.FileFormat = MOI.FileFormats.FORMAT_AUTOMATIC
)
    dest = MOI.FileFormats.Model(format = format, filename = filename)
    # We add a `full_bridge_optimizer` here because MOI.FileFormats models may not
    # support all constraint types in a JuMP model.
    bridged_dest = MOI.Bridges.full_bridge_optimizer(dest, Float64)
    MOI.copy_to(bridged_dest, backend(model))
    # `dest` will contain the underlying model, with constraints bridged if
    # necessary.
    MOI.write_to_file(dest, filename)
    return
end

function write_to_cbf(model,fn_base::String)
    JuMP.write_to_file( model, string(fn_base,".cbf"), format = MOI.FileFormats.FORMAT_CBF)
end

function add_artificial_var_bds(model::JuMP.Model; bd_mag=1e3)
    all_vars = JuMP.all_variables(model)
    for vv in all_vars
        if !has_lower_bound(vv)
            JuMP.@constraint(model, vv >= -bd_mag )
        end
        if !has_upper_bound(vv)
            JuMP.@constraint(model, vv <= bd_mag )
        end
    end
end

function write_to_cbf_scip(model,fn_base::String)
    model_psd = convertSOCtoPSD(model)
    #add_artificial_var_bds(model_psd)
    fname=string(fn_base,"_scip",".cbf")
    JuMP_write_to_file( model_psd, fname, format = MOI.FileFormats.FORMAT_CBF)
    ### CHANGING VER 3 to VER 2 
    fix_version=`sed -i -z 's/VER\n3/VER\n2/g' $fname`
    run(fix_version)
end
