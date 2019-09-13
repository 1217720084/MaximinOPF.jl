using LightGraphs
using Formatting
using JuMP
#using CPLEX, Ipopt, SCS 
using Ipopt 
#using Mosek,MosekTools
using Arpack
using DelimitedFiles
using Printf
using SparseArrays
using LinearAlgebra

#USEFUL SUBROUTINES
function printX(opfdata,x_soln)
  for l in opfdata.L
   if x_soln[l] > 0.5 
	@printf(" %d",l)
   end
  end
end

function get_graph(mat::SparseMatrixCSC{Float64,Int64})
    rows = rowvals(mat)
    vals = nonzeros(mat)
    m, n = size(mat)
    g = SimpleGraph(m)
    for i = 1:n
        for j in nzrange(mat, i)
            # if abs(vals[j]) > 0
                add_edge!(g, rows[j], i)
            # end
        end
    end
    return g
end

# Get the n-by-n chordal extension
function get_chordal_extension(opfdata)
    N, L, fromBus, toBus = opfdata.N, opfdata.L, opfdata.fromBus, opfdata.toBus  
    # Laplacian graph
    I = Int64[]; J = Int64[]; V = Float64[]
    for l in L
        fid = fromBus[l]
        tid = toBus[l]
        push!(I,fid); push!(J,tid); push!(V,-1)
        push!(I,tid); push!(J,fid); push!(V,-1)
    end
    A = sparse(I,J,V)
    for i in N
        push!(I,i); push!(J,i)
        push!(V,-sum(A[i,:])+1)
    end
    A = sparse(I,J,V)
    C = sparse(cholfact(A))
    return C
end

# Get the 2n-by-2n chordal extension
function get_chordal_extension_complex(opfdata)
    N, L, fromBus, toBus = opfdata.N, opfdata.L, opfdata.fromBus, opfdata.toBus  
    # Laplacian graph
    num = length(N)
    I = Int64[]; J = Int64[]; V = Float64[]
    for l in L
        fid = fromBus[l]
        tid = toBus[l]
        push!(I,fid); push!(J,tid); push!(V,-1)
        push!(I,tid); push!(J,fid); push!(V,-1)
        push!(I,fid); push!(J,num+tid); push!(V,-1)
        push!(I,num+tid); push!(J,fid); push!(V,-1)
        push!(I,tid); push!(J,num+fid); push!(V,-1)
        push!(I,num+fid); push!(J,tid); push!(V,-1)
        push!(I,num+fid); push!(J,num+tid); push!(V,-1)
        push!(I,num+tid); push!(J,num+fid); push!(V,-1)
    end
    A = sparse(I,J,V)
    for i in 1:(2*num)
        push!(I,i); push!(J,i)
        push!(V,-sum(A[i,:])+1)
    end
    A = sparse(I,J,V,2*num,2*num)
    # λ, ϕ = eigs(A)
    # @show λ
    C = sparse(cholfact(A))
    return C
end

function KiwielRhoUpdate(opfdata,params,node)
  nextTVal=node.tVal
  oldTVal=node.tVal
  if node.sscval >= params.ssc
    if node.sscval >= max(params.ssc,0.5) && node.ns_cntr > 0
      nextTVal = 2*node.tVal*(1-node.sscval)
    elseif node.ns_cntr > 3
      nextTVal = node.tVal/2
    end
    node.tVal = max(nextTVal, node.tVal/10, params.tMin)
    node.var_est = max(node.var_est,2*node.descent_est)
    node.ns_cntr = max(node.ns_cntr+1,1)
    if oldTVal != node.tVal
      node.ns_cntr = 1
    end
  else
    node.var_est=min(node.var_est,node.agg_sg_norm+node.epshat)
    if node.linerr > max(node.var_est,10*node.descent_est) && node.ns_cntr < -3
      nextTVal = 2*node.tVal*(1-node.sscval)
    end
    node.tVal = min(nextTVal,10*node.tVal)
    node.ns_cntr = min(node.ns_cntr-1,-1)
    if oldTVal != node.tVal
      node.ns_cntr = -1	
    end
  end
end

function testSchrammZoweSSII(opfdata,params,node,mpsoln,ctr)
  return (node.linerr - mpsoln.linobjval + ctr.linobjval + node.rho*(mpsoln.eta-ctr.eta)  >= -0.5*node.descent_est) || node.tVal < max(1.001*params.tMin + 1e-2)
end
function testSchrammZoweNSII(opfdata,params,ctr,node,mpsoln)
  return (node.linerr <= 0.5*node.epshat) ||  abs(ctr.linobjval - mpsoln.linobjval - node.rho*(ctr.eta-mpsoln.eta)) <= node.agg_sg_norm + node.epshat || node.tVal > 0.99*params.tMax
end


function update_agg(opfdata,node,ctr,mpsoln,sg_agg)
  N, L, G = opfdata.N, opfdata.L, opfdata.G 
  comp_agg(opfdata,node,ctr.soln,mpsoln.soln,sg_agg)
  node.agg_sg_norm=comp_norm(opfdata,sg_agg)
  return node.agg_sg_norm
end

function update_rho(node,trl_bundles,ctr_bundles,agg_bundles)
  node.rho = 0 
  ntrlcuts,nctrcuts,naggcuts=length(trl_bundles),length(ctr_bundles),length(agg_bundles)
  if ntrlcuts > 0
    node.rho += sum(trl_bundles[n].cut_dual for n in 1:ntrlcuts) 
  end
  if nctrcuts > 0
    node.rho += sum(ctr_bundles[n].cut_dual for n in 1:nctrcuts) 
  end
  if naggcuts > 0
    node.rho += sum(agg_bundles[n].cut_dual for n in 1:naggcuts)
  end
end

function compute_epshat(opfdata,node,mpsoln,ctr,sg_agg)
  N, L, G = opfdata.N, opfdata.L, opfdata.G 
  node.epshat = mpsoln.linobjval - (ctr.linobjval - node.rho*ctr.eta) - (1.0/node.tVal)*comp_norm(opfdata,sg_agg)^2
  return node.epshat
end

function updateCenter(opfdata,mpsoln,ctr,trl_bundles,ctr_bundles,agg_bundles)
  nbuses, nlines, ngens, N, L, G = opfdata.nbuses, opfdata.nlines, opfdata.ngens, opfdata.N, opfdata.L, opfdata.G 
  fromBus,toBus,Y = opfdata.fromBus, opfdata.toBus, opfdata.Y_AC
  cpy_bundle(opfdata,mpsoln,ctr)
end

function computeSG(opfdata,mpsoln)
      nbuses, nlines, ngens, N, L, G = opfdata.nbuses, opfdata.nlines, opfdata.ngens, opfdata.N, opfdata.L, opfdata.G 
      fromBus,toBus,Y = opfdata.fromBus, opfdata.toBus, opfdata.Y_AC
      vR = zeros(nbuses)
      vI = zeros(nbuses)
      success=true
      try
        mpsoln.eta = -solveEta0Eigs(opfdata,mpsoln.soln,vR,vI)
      catch exc
        println("Exception caught with eigs(), solving η0Val subproblem with Ipopt as recourse.")
        println(exc)
        mpsoln.eta,status = solveEta0SDP(opfdata,mpsoln.soln,vR,vI)
	mpsoln.eta *= -1
        if !(status == MOI.OPTIMAL || status == MOI.LOCALLY_SOLVED)
	  success=false
	end
      end
      if success
        for i in N
          W_val = vR[i]^2 + vI[i]^2
          mpsoln.eta_sg.α[i] = Y["shR"][i] * W_val
	  mpsoln.eta_sg.β[i] = -Y["shI"][i] * W_val
          mpsoln.eta_sg.δ[i] = W_val
	  mpsoln.eta_sg.γ[i] = -W_val
        end
        for l in L
          from = fromBus[l]; to = toBus[l]
          e_valF = vR[from]; f_valF = vI[from]; W_valF = e_valF^2 + f_valF^2
          e_valT = vR[to]; f_valT = vI[to]; W_valT = e_valT^2 + f_valT^2
          Wr_val = e_valF*e_valT + f_valF*f_valT; Wi_val = e_valT*f_valF - e_valF*f_valT
          mpsoln.eta_sg.λF[l] = (Y["ffR"][l] * W_valF + Y["ftR"][l] * Wr_val + Y["ftI"][l] * Wi_val)
          mpsoln.eta_sg.λT[l] = (Y["ttR"][l] * W_valT + Y["tfR"][l] * Wr_val - Y["tfI"][l] * Wi_val)
          mpsoln.eta_sg.μF[l] = (-Y["ffI"][l] * W_valF - Y["ftI"][l] * Wr_val + Y["ftR"][l] * Wi_val)
          mpsoln.eta_sg.μT[l] = (-Y["ttI"][l] * W_valT - Y["tfI"][l] * Wr_val - Y["tfR"][l] * Wi_val)
        end
      end
      return mpsoln.eta,success
end
# SUBROUTINE FOR COMPUTING THE MINIMUM EIGENVALUE OF H WITH A CORRESPONDING EIGENVECTOR
function solveEta0Eigs(opfdata,soln,vR,vI)
      nbuses, nlines, ngens, N, L, G = opfdata.nbuses, opfdata.nlines, opfdata.ngens, opfdata.N, opfdata.L, opfdata.G 
      fromBus,toBus = opfdata.fromBus, opfdata.toBus
      H=spzeros(2*nbuses,2*nbuses)
      updateHess(opfdata,soln,H)
      E=eigs(H,nev=1,which=:SR, maxiter=100000, tol=1e-6)
      η0Val = E[1][1]
      for i in N
        vR[i] = E[2][i,1]; vI[i] = E[2][nbuses+i,1]
      end
      return η0Val
end
# Update Hessian
function updateHess(opfdata,pi_val,H)
      #lines, buses, generators, baseMVA = opfdata.lines, opfdata.buses, opfdata.generators, opfdata.baseMVA
      nbuses, nlines, ngens, N, L, G = opfdata.nbuses, opfdata.nlines, opfdata.ngens, opfdata.N, opfdata.L, opfdata.G 
      fromBus,toBus = opfdata.fromBus, opfdata.toBus  
      Y = opfdata.Y_AC
      for i in N
        H[i,i] +=  pi_val.α[i] * Y["shR"][i] - pi_val.β[i] * Y["shI"][i]  + pi_val.δ[i] - pi_val.γ[i]
        H[nbuses+i,nbuses+i] += pi_val.α[i] * Y["shR"][i] - pi_val.β[i] * Y["shI"][i] + pi_val.δ[i] - pi_val.γ[i]
      end
      for l in L
        from = fromBus[l]; to = toBus[l]
        H[from,from] += pi_val.λF[l] * Y["ffR"][l] - pi_val.μF[l] * Y["ffI"][l]
        H[nbuses+from,nbuses+from] += pi_val.λF[l] * Y["ffR"][l] - pi_val.μF[l] * Y["ffI"][l]
        H[to,to] += pi_val.λT[l] * Y["ttR"][l] - pi_val.μT[l] * Y["ttI"][l]
        H[nbuses+to,nbuses+to] += pi_val.λT[l] * Y["ttR"][l] - pi_val.μT[l] * Y["ttI"][l]
        H[from,to] += 0.5*( pi_val.λF[l] * Y["ftR"][l] - pi_val.μF[l] * Y["ftI"][l] + pi_val.λT[l] * Y["tfR"][l] - pi_val.μT[l] * Y["tfI"][l] )
        H[to,from] += 0.5*( pi_val.λF[l] * Y["ftR"][l] - pi_val.μF[l] * Y["ftI"][l] + pi_val.λT[l] * Y["tfR"][l] - pi_val.μT[l] * Y["tfI"][l] )
        H[nbuses+from, nbuses+to] += 0.5*( pi_val.λF[l] * Y["ftR"][l] - pi_val.μF[l] * Y["ftI"][l] + pi_val.λT[l] * Y["tfR"][l] - pi_val.μT[l] * Y["tfI"][l] )
        H[nbuses+to, nbuses+from] += 0.5*( pi_val.λF[l] * Y["ftR"][l] - pi_val.μF[l] * Y["ftI"][l] + pi_val.λT[l] * Y["tfR"][l] - pi_val.μT[l] * Y["tfI"][l] )
        H[to, nbuses+from] += 0.5*( pi_val.λF[l] * Y["ftI"][l] - pi_val.λT[l] * Y["tfI"][l] + pi_val.μF[l] * Y["ftR"][l] - pi_val.μT[l] * Y["tfR"][l] )
        H[nbuses+from, to] += 0.5*( pi_val.λF[l] * Y["ftI"][l] - pi_val.λT[l] * Y["tfI"][l] + pi_val.μF[l] * Y["ftR"][l] - pi_val.μT[l] * Y["tfR"][l] )
        H[from,nbuses+to] -= 0.5*( pi_val.λF[l] * Y["ftI"][l] - pi_val.λT[l] * Y["tfI"][l] + pi_val.μF[l] * Y["ftR"][l] - pi_val.μT[l] * Y["tfR"][l] )
        H[nbuses+to,from] -= 0.5*( pi_val.λF[l] * Y["ftI"][l] - pi_val.λT[l] * Y["tfI"][l] + pi_val.μF[l] * Y["ftR"][l] - pi_val.μT[l] * Y["tfR"][l] )
      end
end


# SUBROUTINE FOR COMPUTING THE MINIMUM EIGENVALUE OF H WITH A CORRESPONDING EIGENVECTOR
  # VIA AN OPTIMIZATION PROBLEM
function solveEta0SDP(opfdata,soln,vR,vI)
      nbuses, nlines, ngens, N, L, G = opfdata.nbuses, opfdata.nlines, opfdata.ngens, opfdata.N, opfdata.L, opfdata.G 
      fromBus,toBus = opfdata.fromBus, opfdata.toBus

      #The QP subproblem
      mSDP = Model(with_optimizer(Ipopt.Optimizer))
      @variable(mSDP, e[i=N], start=0); @variable(mSDP, f[i=N], start=0)
      η0Val = 0

      for i in N
        setvalue(e[i], 1); setvalue(f[i], 0)
      end

      H=spzeros(2*nbuses,2*nbuses)
      updateHess(opfdata,soln,H)

      # Adjust QP subproblem
      @NLobjective(mSDP, Min, sum( H[i,i]*(e[i]^2+f[i]^2) for i in N)
        + 2*sum( H[fromBus[l],toBus[l]]*(e[fromBus[l]]*e[toBus[l]]+f[fromBus[l]]*f[toBus[l]])   for l in L)
        - 2*sum( H[fromBus[l],nbuses+toBus[l]]*(f[fromBus[l]]*e[toBus[l]]-e[fromBus[l]]*f[toBus[l]])   for l in L)
      )
      JuMP.optimize!(mSDP)
      status=JuMP.termination_status(mSDP)
      if status == MOI.OPTIMAL || status == MOI.LOCALLY_SOLVED
        η0Val = getobjectivevalue(mSDP)
        for i in N
          vR[i],vI[i]=getvalue(e[i]),getvalue(f[i])
        end
        if(status == :UserLimit)
          println("solveEta0SDP solve status $status")
        end
      else
        println("solveEta0SDP: solve status $status")
        η0Val = 0
      end
      return η0Val,status
end

# SUBROUTINE FOR COMPUTING A SUBGRADIENT OF ETA(PI), WHICH IS THE FUNCTION TAKING THE VALUE OF THE MINIMUM EIGENVALUE OF H(PI)
function purgeSG(opfdata,bundle,minAge=0,maxAge=1)
      nbuses, nlines, ngens, N, L, G = opfdata.nbuses, opfdata.nlines, opfdata.ngens, opfdata.N, opfdata.L, opfdata.G 
      fromBus,toBus,Y = opfdata.fromBus, opfdata.toBus, opfdata.Y_AC

      orig_ncuts = length(bundle)
      ncuts = orig_ncuts
      for n=orig_ncuts:-1:1
        if (abs(bundle[n].cut_dual) < 1e-8 && bundle[n].age > minAge) || (bundle[n].age > maxAge)
	  bundle[n]=bundle[ncuts]
	  delete!(bundle,ncuts)
	  ncuts -= 1
	end
      end
      for n=1:length(bundle)
	bundle[n].age += 1
      end
      return length(bundle)
end

function aggregateSG(opfdata,trl_bundles,mpsoln,ctr,ctr_bundles,agg_bundles)
      nbuses, nlines, ngens, N, L, G = opfdata.nbuses, opfdata.nlines, opfdata.ngens, opfdata.N, opfdata.L, opfdata.G 
      fromBus,toBus,Y = opfdata.fromBus, opfdata.toBus, opfdata.Y_AC
      agg_bundle=create_bundle(opfdata)

      cpy_soln(opfdata,mpsoln.soln,agg_bundle.soln)
      sumDuals,ncuts,nctrcuts,naggcuts = 0.0,length(trl_bundles),length(ctr_bundles),length(agg_bundles)
      if ncuts > 0
        sumDuals += sum(trl_bundles[n].cut_dual for n in 1:ncuts) 
      end
      if nctrcuts > 0
        sumDuals += sum(ctr_bundles[n].cut_dual for n in 1:nctrcuts) 
      end
      if naggcuts > 0
        sumDuals += sum(agg_bundles[n].cut_dual for n in 1:naggcuts) 
      end

      agg_bundle.eta_sg.α[N] .= 0
      agg_bundle.eta_sg.β[N] .= 0
      agg_bundle.eta_sg.γ[N] .= 0
      agg_bundle.eta_sg.δ[N] .= 0
      agg_bundle.eta_sg.ζpLB[G] .= 0
      agg_bundle.eta_sg.ζpUB[G] .= 0
      agg_bundle.eta_sg.ζqLB[G] .= 0
      agg_bundle.eta_sg.ζqUB[G] .= 0
      agg_bundle.eta_sg.x[L] .= 0
      agg_bundle.eta_sg.λF[L] .= 0
      agg_bundle.eta_sg.λT[L] .= 0
      agg_bundle.eta_sg.μF[L] .= 0
      agg_bundle.eta_sg.μT[L] .= 0

      agg_bundle.objval = 0
      agg_bundle.linobjval = 0
      agg_bundle.penval = 0
      agg_bundle.psival = 0

      if ncuts > 0
        agg_bundle.eta_sg.α[N] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.α[N] for n in 1:ncuts) )
        agg_bundle.eta_sg.β[N] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.β[N] for n in 1:ncuts) )
        agg_bundle.eta_sg.γ[N] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.γ[N] for n in 1:ncuts) )
        agg_bundle.eta_sg.δ[N] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.δ[N] for n in 1:ncuts) )
        agg_bundle.eta_sg.ζpLB[G] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.ζpLB[G] for n in 1:ncuts) )
        agg_bundle.eta_sg.ζpUB[G] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.ζpUB[G] for n in 1:ncuts) )
        agg_bundle.eta_sg.ζqLB[G] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.ζqLB[G] for n in 1:ncuts) )
        agg_bundle.eta_sg.ζqUB[G] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.ζqUB[G] for n in 1:ncuts) )
        agg_bundle.eta_sg.x[L]  += (1/sumDuals)* ( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.x[L] for n in 1:ncuts) )
        agg_bundle.eta_sg.λF[L] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.λF[L] for n in 1:ncuts) )
        agg_bundle.eta_sg.λT[L] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.λT[L] for n in 1:ncuts) )
        agg_bundle.eta_sg.μF[L] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.μF[L] for n in 1:ncuts) )
        agg_bundle.eta_sg.μT[L] += (1/sumDuals)*( sum( trl_bundles[n].cut_dual*trl_bundles[n].eta_sg.μT[L] for n in 1:ncuts) )

      end
      if nctrcuts > 0
        agg_bundle.eta_sg.α[N] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.α[N] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.β[N] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.β[N] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.γ[N] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.γ[N] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.δ[N] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.δ[N] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.ζpLB[G] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.ζpLB[G] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.ζpUB[G] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.ζpUB[G] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.ζqLB[G] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.ζqLB[G] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.ζqUB[G] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.ζqUB[G] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.x[L]  += (1/sumDuals)* ( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.x[L] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.λF[L] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.λF[L] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.λT[L] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.λT[L] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.μF[L] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.μF[L] for n in 1:nctrcuts) )
        agg_bundle.eta_sg.μT[L] += (1/sumDuals)*( sum( ctr_bundles[n].cut_dual*ctr_bundles[n].eta_sg.μT[L] for n in 1:nctrcuts) )

      end
      if naggcuts > 0
        agg_bundle.eta_sg.α[N] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.α[N] for n in 1:naggcuts) )
        agg_bundle.eta_sg.β[N] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.β[N] for n in 1:naggcuts) )
        agg_bundle.eta_sg.γ[N] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.γ[N] for n in 1:naggcuts) )
        agg_bundle.eta_sg.δ[N] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.δ[N] for n in 1:naggcuts) )
        agg_bundle.eta_sg.ζpLB[G] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.ζpLB[G] for n in 1:naggcuts) )
        agg_bundle.eta_sg.ζpUB[G] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.ζpUB[G] for n in 1:naggcuts) )
        agg_bundle.eta_sg.ζqLB[G] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.ζqLB[G] for n in 1:naggcuts) )
        agg_bundle.eta_sg.ζqUB[G] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.ζqUB[G] for n in 1:naggcuts) )
        agg_bundle.eta_sg.x[L]  += (1/sumDuals)* ( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.x[L] for n in 1:naggcuts) )
        agg_bundle.eta_sg.λF[L] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.λF[L] for n in 1:naggcuts) )
        agg_bundle.eta_sg.λT[L] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.λT[L] for n in 1:naggcuts) )
        agg_bundle.eta_sg.μF[L] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.μF[L] for n in 1:naggcuts) )
        agg_bundle.eta_sg.μT[L] += (1/sumDuals)*( sum( agg_bundles[n].cut_dual*agg_bundles[n].eta_sg.μT[L] for n in 1:naggcuts) )

      end
      agg_bundle.age = 1
      agg_bundle.eta = mpsoln.eta
      return agg_bundle
end

function incT(node)
  if node.tVal >= 1
    node.tVal = floor(node.tVal)
    node.tVal += 1
  else
    node.tVal = ceil(1.0/node.tVal)-1
    node.tVal = 1.0/node.tVal
  end
end

function decT(node)
  if node.tVal > 1
    node.tVal = ceil(node.tVal)
    node.tVal -= 1
  else
    node.tVal = floor(1.0/node.tVal)+1
    node.tVal = 1.0/node.tVal
  end
end

function computeMPSoln(opfdata,node_data,K,PROX_PARAM,ctr,trl_bundles,ctr_bundles,agg_bundles)
  mpsoln=create_bundle(opfdata)
  mMP = createBasicMP(opfdata,node_data,K,PROX_PARAM)
  setObjMP(opfdata,mMP,node_data,ctr,PROX_PARAM)
  solveNodeMP(opfdata,mMP,node_data,trl_bundles,ctr_bundles,agg_bundles,ctr,PROX_PARAM,mpsoln)
  while mpsoln.status != MOI.OPTIMAL && mpsoln.status != MOI.LOCALLY_SOLVED
    node_data.tVal /= 2
    println("Status was: ",mpsoln.status,". Resolving with reduced prox parameter value: ",node_data.tVal)
    mMP = createBasicMP(opfdata,node_data,K,PROX_PARAM)
    setObjMP(opfdata,mMP,node_data,ctr,PROX_PARAM)
    solveNodeMP(opfdata,mMP,node_data,trl_bundles,ctr_bundles,agg_bundles,ctr,PROXPARAM,mpsoln)
  end	
  return mpsoln
end
