module MaximinOPF
using PowerModels
include("Variables.jl")
include("Objectives.jl")
include("Constraints.jl")
greet() = print("Hello World!")

function MaximinOPFModel(pm_data, powerform, nLineAttacked)
	println("Hello MaximinOPFModel")
	#println(case)
	println(powerform)
	println(nLineAttacked)
	pm = ""
	#Output Model from PowerModels

    if powerform == SOCWRConicPowerModel
        println("Prototyping Algo")
        for (k,line) in pm_data["branch"]
          if line["index"] in pm_data["inactive_branches"]
	    line["br_status"]=0
          end			
        end		
        #pm = build_model(pm_data, powerform, SOCWRConicPost_PF_Feas)
        pm = build_model(pm_data, powerform, SOCWRConicPost_PF_Minmax)
	elseif (powerform == SDPWRMPowerModel)
		println("Brian Algo")
		pm = build_model(case, powerform, post_pf_feas)
	else
		println("Default Algo")
		pm = build_model(case, powerform, myPost_OPF)
	end

	return pm
end


function SOCWRConicPost_PF_Minmax(pm::AbstractPowerModel)
    SOCWRConicPost_PF(pm)
    variable_ordering_auxiliary(pm)
    con(pm, pm.cnw, pm.ccnd)[:x] = Dict{Int,ConstraintRef}()
    for l in ids(pm, :branch)
      if !(l in pm.data["protected_branches"])
        constraint_def_abs_flow_values(pm, l)
        constraint_abs_branch_flow_ordering(pm, l)
      end
    end
    K=pm.data["attacker_budget"]
    objective_minmax_problem(pm,K)
end

function SOCWRConicPost_PF(pm::AbstractPowerModel)
    variable_voltage(pm)
    variable_generation(pm)
    variable_branch_flow(pm)
    variable_dcline_flow(pm)
    remove_infinity_bnds(pm)

    # Add new variables
    variable_bus_slacks(pm)
    variable_branch_flow_slacks(pm)

    # Post objective function for testing fisibility problem
    # objective_feasibility_problem(pm)

    constraint_model_voltage(pm)

    for i in ids(pm, :ref_buses)
        constraint_theta_ref(pm, i)
    end

    for i in ids(pm, :bus)
        # Replace power balnce constraint function
        # constraint_power_balance(pm, i)
        constraint_power_balance_slacks(pm, i)
    end

    for l in ids(pm, :branch)
	if l in pm.data["protected_branches"]
          constraint_ohms_yt_from(pm, l)
          constraint_ohms_yt_to(pm, l)
	else
          constraint_ohms_yt_from_slacks(pm, l)
          constraint_ohms_yt_to_slacks(pm, l)
	end

        constraint_voltage_angle_difference(pm, l)

        constraint_thermal_limit_from(pm, l)
        constraint_thermal_limit_to(pm, l)
    end

    for l in ids(pm, :dcline)
        constraint_dcline(pm, l)  # DO WE NEED TO TREAT THESE CONSTRAINTS DIFFERENTLY
    end
end


function myPost_OPF(pm::AbstractPowerModel)
	variable_voltage(pm)
    variable_generation(pm)
    variable_branch_flow(pm)
    variable_dcline_flow(pm)

    objective_min_fuel_and_flow_cost(pm)

    constraint_model_voltage(pm)

    for i in ids(pm, :ref_buses)
        constraint_theta_ref(pm, i)
    end

    for i in ids(pm, :bus)
        constraint_power_balance(pm, i)
    end

    for i in ids(pm, :branch)
        constraint_ohms_yt_from(pm, i)
        constraint_ohms_yt_to(pm, i)

        constraint_voltage_angle_difference(pm, i)

        constraint_thermal_limit_from(pm, i)
        constraint_thermal_limit_to(pm, i)
    end

    for i in ids(pm, :dcline)
        constraint_dcline(pm, i)
    end
end

end # module
