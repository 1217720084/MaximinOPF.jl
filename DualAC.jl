#=
Template for branch-and-cut method

July 5, 2018
Kibaek Kim
Brian Dandurand
=#

include("utils.jl")

type SolnInfo
  x_soln::Array{Float64}
  x_dualsoln::Array{Float64}
  optval::Float64
  solvetime::Float64
end

type NodeInfo
  x_lbs::Array{Float64}
  x_ubs::Array{Float64}
  nodeBd::Float64
end

function solveNodeAC(opfdata,ndata,mpsoln)
  # OBTAIN PROBLEM INFORMATION FROM opfdata
    nbuses, nlines, ngens = opfdata.nbuses, opfdata.nlines, opfdata.ngens
    N, L, G = opfdata.N, opfdata.L, opfdata.G 
    fromLines,toLines,fromBus,toBus = opfdata.fromLines, opfdata.toLines, opfdata.fromBus, opfdata.toBus
    BusGeners, Y = opfdata.BusGeners, opfdata.Y_AC

    # indicate to enable chordal decomposition
    chordal_decomposition = false

  # Instantiating the model and solver for the dual problem
    nThreads=1
    #mMP = Model(solver=MosekSolver(MSK_IPAR_LOG=0,MSK_IPAR_NUM_THREADS=nThreads))
    mMP = Model(solver=SCSSolver(verbose=1,max_iters=1000000))
    @variable(mMP, -1 <= α[i=N] <= 1)
    @variable(mMP, -1 <= β[i=N] <= 1)
    @variable(mMP, γp[i=N] >= 0)
    @variable(mMP, γm[i=N] >= 0)
    @constraint(mMP, [i=N], γp[i]+γm[i] <= 1)
    @variable(mMP, ζpUB[g=G] >= 0)
    @variable(mMP, ζpLB[g=G] >= 0)
    @variable(mMP, ζqUB[g=G] >= 0)
    @variable(mMP, ζqLB[g=G] >= 0)
    @variable(mMP, ndata.x_lbs[l] <= x[l=L] <= ndata.x_ubs[l])
    @constraint(mMP, sum(x[l] for l in L) <= K)

  for i in N
   for g in BusGeners[i]
    @constraint(mMP,
    -α[i] + ζpUB[g] - ζpLB[g] == 0 )
    @constraint(mMP,
    -β[i] + ζqUB[g] - ζqLB[g] == 0 )
   end
  end
  # McCormick inequalities enforcing bilinear equalities
    # auxiliary dual variables due to McCormick reformulation of cross terms appearing in the Lagrangian
      @variable(mMP, λF[l=L]); @variable(mMP, λT[l=L]); @variable(mMP, μF[l=L]); @variable(mMP, μT[l=L])
    @constraint(mMP, AMcf1[l in L], α[fromBus[l]] - x[l] <= λF[l]); @constraint(mMP, AMcf2[l in L], α[fromBus[l]] + x[l] >= λF[l])
    @constraint(mMP, AMcf3[l in L], -(1 - x[l]) <= λF[l]); @constraint(mMP, AMcf4[l in L], (1 - x[l]) >= λF[l])
    @constraint(mMP, AMct1[l in L], α[toBus[l]] - x[l] <= λT[l]); @constraint(mMP, AMct2[l in L], α[toBus[l]] + x[l] >= λT[l])
    @constraint(mMP, AMct3[l in L], -(1 - x[l]) <= λT[l]); @constraint(mMP, AMct4[l in L], (1 - x[l]) >= λT[l])

    @constraint(mMP, BMcf1[l in L], β[fromBus[l]] - x[l] <= μF[l]); @constraint(mMP, BMcf2[l in L], β[fromBus[l]] + x[l] >= μF[l])
    @constraint(mMP, BMcf3[l in L], -(1 - x[l]) <= μF[l]); @constraint(mMP, BMcf4[l in L], (1 - x[l]) >= μF[l])
    @constraint(mMP, BMct1[l in L], β[toBus[l]] - x[l] <= μT[l]); @constraint(mMP, BMct2[l in L], β[toBus[l]] + x[l] >= μT[l])
    @constraint(mMP, BMct3[l in L], -(1 - x[l]) <= μT[l]); @constraint(mMP, BMct4[l in L], (1 - x[l]) >= μT[l])

  @expression(mMP, C[i=1:(2*nbuses),j=i:(2*nbuses)], 0)
  for i in N
    C[i,i] += γp[i] - γm[i] + α[i]*Y["shR"][i] - β[i]*Y["shI"][i]
        C[nbuses+i,nbuses+i] += γp[i] - γm[i] + α[i]*Y["shR"][i] - β[i]*Y["shI"][i]
    for l in fromLines[i]
      C[i,i] += λF[l]*Y["ffR"][l] - μF[l]*Y["ffI"][l]
      C[nbuses+i,nbuses+i] += λF[l]*Y["ffR"][l] - μF[l]*Y["ffI"][l]
    end
    for l in toLines[i]
      C[i,i] += λT[l]*Y["ttR"][l] - μT[l]*Y["ttI"][l]
      C[nbuses+i,nbuses+i] += λT[l]*Y["ttR"][l] - μT[l]*Y["ttI"][l]
    end
  end
  for l in L
      from=fromBus[l]; to=toBus[l]
      C[from,nbuses+to] -= 0.5*(  λF[l]*Y["ftI"][l] + μF[l]*Y["ftR"][l] - λT[l]*Y["tfI"][l] - μT[l]*Y["tfR"][l]  )
      C[to,nbuses+from] += 0.5*(  λF[l]*Y["ftI"][l] + μF[l]*Y["ftR"][l] - λT[l]*Y["tfI"][l] - μT[l]*Y["tfR"][l]  )
      if from < to
        C[from,to] += 0.5*(λF[l]*Y["ftR"][l]  - μF[l]*Y["ftI"][l] + λT[l]*Y["tfR"][l] - μT[l]*Y["tfI"][l])
        C[nbuses+from,nbuses+to] += 0.5*(λF[l]*Y["ftR"][l]  - μF[l]*Y["ftI"][l] + λT[l]*Y["tfR"][l] - μT[l]*Y["tfI"][l])
      else
        C[to,from] += 0.5*(λF[l]*Y["ftR"][l]  - μF[l]*Y["ftI"][l] + λT[l]*Y["tfR"][l] - μT[l]*Y["tfI"][l])
        C[nbuses+to,nbuses+from] += 0.5*(λF[l]*Y["ftR"][l]  - μF[l]*Y["ftI"][l] + λT[l]*Y["tfR"][l] - μT[l]*Y["tfI"][l])
      end
  end

    if chordal_decomposition
        # Compute new topology for each node subproblem
        nodeL = Int64[]
        for l=L
            #if ndata[l] != 1
	    if abs(ndata.x_ubs[l] - ndata.x_lbs[l]) < 1e-6 
                push!(nodeL,l)
            end
        end

        # Get maximal cliques from the chordal extension of the network topology
        chordal = get_chordal_extension_complex(opfdata)
        max_cliques = maximal_cliques(get_graph(chordal))

        # Applying Agler's theorem (matrix decomposition)
        subH = Dict{Int64,Any}()
        @expression(mMP, sumH[i=1:(2*nbuses),j=i:(2*nbuses)], 0)
        @show length(max_cliques)
        for k in 1:length(max_cliques)
            clique = sort(max_cliques[k])
            num_nodes = length(clique)
            # @show (k,clique)
            subH[k] = @variable(mMP, [i=1:num_nodes,j=1:num_nodes], SDP)
            for i=1:num_nodes, j=i:num_nodes
                sumH[clique[i],clique[j]] += subH[k][i,j]
             end
        end
        @constraint(mMP, [i=1:(2*nbuses),j=i:(2*nbuses)], C[i,j] - sumH[i,j] == 0)
    else
        # SDP matrix
        @variable(mMP, H[i=1:(2*nbuses),j=1:(2*nbuses)], SDP)
        @constraint(mMP, SetH[i=1:(2*nbuses),j=i:(2*nbuses)], C[i,j] - H[i,j] == 0)
    end

  @objective(mMP, Max, sum(ζpLB[g]*opfdata.Pmin[g] - ζpUB[g]*opfdata.Pmax[g] + ζqLB[g]*opfdata.Qmin[g] - ζqUB[g]*opfdata.Qmax[g]  for g in G)
    + sum( γm[i]*opfdata.Wmin[i]-γp[i]*opfdata.Wmax[i] + α[i]*opfdata.PD[i] + β[i]*opfdata.QD[i] for i in N))



  #These constraints are not quite valid, but their inclusion often results in much faster time to near optimal solution.

  if HEUR == 1
      @constraint(mMP, LambdaMuConstr1[l in L], λF[l]*Y["ftI"][l] - λT[l]*Y["tfI"][l] + μF[l]*Y["ftR"][l] - μT[l]*Y["tfR"][l] == 0.0)
  elseif HEUR == 2
    @constraint(mMP, LambdaFequalsT[l in L], λF[l] - λT[l] == 0)
    @constraint(mMP, muFequalsT[l in L], μF[l] - μT[l] == 0)
  elseif HEUR == 3
    @constraint(mMP, LambdaMuConstr2[l in L], λF[l]*Y["tfR"][l] - λT[l]*Y["ftR"][l] - μF[l]*Y["tfI"][l] + μT[l]*Y["ftI"][l] == 0.0)
  end

  status=solve(mMP)
  if status == :Optimal || status == :Stall
      for l in L
        mpsoln.x_soln[l] = getvalue(x[l])
        from=fromBus[l]; to=toBus[l]
        mpsoln.x_dualsoln[l] = getdual(x[l])  
      end
      mpsoln.optval = getobjectivevalue(mMP)
      mpsoln.solvetime = getsolvetime(mMP)
      if status == :Stall
        println("solveNodeAC: Return status $status")
      end
  else
    println("solveNodeAC: Return status $status")
  end
end #end of function

function xIntTol(opfdata,mpsoln)
    x_val = mpsoln.x_soln
    tol = 1e-6
    for l in opfdata.L
      if min(abs(x_val[l]),abs(1-x_val[l])) > tol
    return false
      end
    end
    # at this point, x_val is verified to be binary within tolerance
    for l in opfdata.L
    x_val[l] = round(x_val[l])
    end
    return true
end
function findBranchIdx(opfdata,x_val)
  maxidx=1
  maxval=min(x_val[1], 1-x_val[1])
  for l in opfdata.L
    if min(x_val[l], 1-x_val[l]) > maxval
    maxidx=l
    maxval = min(x_val[l],1-x_val[l])
    end
  end
  return maxidx,maxval
end

function findBranchIdx2(opfdata,x_val)
  absCoeff=zeros(opfdata.nlines)
  Y = opfdata.Y_AC
  for l in opfdata.L
    absCoeff[l] =
      sqrt(Y["ffR"][l]^2 + Y["ffI"][l]^2 + Y["ttR"][l]^2 + Y["ttI"][l]^2
      + Y["ftR"][l]^2 + Y["ftI"][l]^2 + Y["tfR"][l]^2 + Y["tfI"][l]^2)
  end
  maxidx=1
  maxval=absCoeff[1]*min(x_val[1], 1-x_val[1])
  for l in opfdata.L
    if absCoeff[l]*min(x_val[l], 1-x_val[l]) > maxval
    maxidx=l
    maxval = absCoeff[l]*min(x_val[l],1-x_val[l])
    end
  end
  return maxidx,maxval
end
function findBranchIdx3(opfdata,x_val,xDualVals)
  maxidx=1
  maxval=xDualVals[1]*min(x_val[1], 1-x_val[1])
  for l in opfdata.L
    if xDualVals[l]*min(x_val[l], 1-x_val[l]) > maxval
    maxidx=l
    maxval = xDualVals[l]*min(x_val[l],1-x_val[l])
    end
  end
  return maxidx,maxval
end

function findNextNode(opfdata,E)
  nodekey=-1e20
  weakestUBVal = -1e20
  for (k,n) in E
    if n[2].nodeBd > weakestUBVal
    nodekey = n[1]
        weakestUBVal = n[2].nodeBd
    end
  end
  return nodekey,weakestUBVal
end

function testDualAC(opfdata)
  x_val=zeros(opfdata.nlines)
  x_val[41]=1
  x_val[80]=1
  fixedNode=NodeInfo(x_val,x_val,1e20)

  mpsoln = SolnInfo(zeros(opfdata.nlines),ones(opfdata.nlines),1e20,0)

  solveNodeAC(opfdata,fixedNode,mpsoln)
  dualObjval = mpsoln.optval
  primalObjval = solveFullModelSDP(opfdata,x_val)
  println("Primal value: ",primalObjval," and dual value: ",dualObjval)
end


function solveBnBSDP(opfdata,incSoln)
  global MAX_TIME
  nlines,L = opfdata.nlines, opfdata.L

  mpsoln = SolnInfo(zeros(nlines),ones(nlines),1e20,0)


  start_time = time_ns()
  BnBTree = Dict()
  #nodedata = Dict()
  BnBTree[0] = NodeInfo(zeros(nlines),ones(nlines),1e20)
  #nodedata[0] = -1*ones(nlines+1)
  #nodedata[0][nlines+1]=1e20
  nodekey=0

  feasXs = Dict()
  incsoln = SolnInfo(zeros(nlines),ones(nlines),0.0,0.0)

  bestUBVal=1e20

  nNodes=1
  maxidx=1
  maxval=-1
  E=enumerate(BnBTree)
  while true
    println("There are ",length(E)," nodes left out of a total of ", nNodes," generated.")
    currNode = pop!(BnBTree,nodekey)
    objval=currNode.nodeBd
    if objval <= incSoln.optval
        println("\tFathoming due to initial testing of bound $objval < ",incSoln.optval)
    else
      print("\t Fixing the following x: ")
      for l in L
        if abs(currNode.x_lbs[l] - currNode.x_ubs[l]) < 1e-6
          print(" x[$l]=",round(0.5*(currNode.x_lbs[l]+currNode.x_ubs[l])) )
        end
      end
      print("\n")
      solveNodeAC(opfdata,currNode,mpsoln)
      x_val = mpsoln.x_soln
      objval = mpsoln.optval
      soltime = mpsoln.solvetime
      if objval < incSoln.optval
        println("\t\tFathoming due to bound $objval < ",incSoln.optval)
      else
    # Apply primal heuristic
        if xIntTol(opfdata,mpsoln)
          println("\t\tFathoming due to optimality")
          # Apply primal heuristic
          primHeurXInt(opfdata,mpsoln,feasXs,incSoln)
        else
          maxidx,maxval=findBranchIdx2(opfdata,x_val)
          println("\t\tBranching on index $maxidx with value $maxval")
          upNLBs = zeros(nlines); upNLBs .= currNode.x_lbs
          upNUBs = zeros(nlines); upNUBs .= currNode.x_ubs
	  upNLBs[maxidx]=1
	  upNUBs[maxidx]=1
          BnBTree[nNodes]=NodeInfo(upNLBs,upNUBs,objval)
          nNodes += 1

          downNLBs = zeros(nlines); downNLBs .= currNode.x_lbs
          downNUBs = zeros(nlines); downNUBs .= currNode.x_ubs
	  downNLBs[maxidx]=0
	  downNUBs[maxidx]=0
          BnBTree[nNodes]=NodeInfo(downNLBs,downNUBs,objval)
          nNodes += 1

          # Apply primal heuristic
            primHeur(opfdata,mpsoln,feasXs,incSoln)
        end
      end #not fathomed due to bound after solving node
    end # no intial fathoming
    E=enumerate(BnBTree)
    if length(E) > 0
      nodekey,bestUBVal=findNextNode(opfdata,E)
    else
      bestUBVal = incSoln.optval
      break
    end
    if (time_ns()-start_time)/1e9 > MAX_TIME
    break
    end
    println("\t\t\tBest UB $bestUBVal versus incumbent value ",incSoln.optval)
  end # while
  end_time = time_ns()

  runtime = (end_time-start_time)/1e9
  return bestUBVal,nNodes,runtime
end

function primHeur(opfdata,mpsoln,feasXs,incSoln)
  nlines=opfdata.nlines
  sortIdx = zeros(Int,nlines)
  sortperm!(sortIdx,mpsoln.x_soln[1:nlines])
  bestKIdx = sortIdx[(nlines-K+1):nlines]
  pX = SolnInfo(zeros(nlines),ones(nlines),0.0,0.0)
  pX.x_soln[bestKIdx] = 1
  Xs = enumerate(feasXs)
  isNewX = true
  for (k,feasx) in Xs
    if sum( abs(pX.x_soln[l]-feasx[2].x_soln[l]) for l=1:nlines ) < 1e-6
    isNewX=false
    break
    end
  end
  if isNewX
    nXs = length(feasXs)+1
    feasXs[nXs]=pX
    solveNodeAC(opfdata,NodeInfo(pX.x_soln,pX.x_soln,1e20),pX)
    if pX.optval > incSoln.optval
      incSoln.optval = pX.optval
      incSoln.x_soln .= pX.x_soln
      print("\t\t\tNew incumbent solution: ")
      printX(opfdata,pX.x_soln)
      println(" with value: ", pX.optval)
    end
  end
end

function primHeurXInt(opfdata,mpsoln,feasXs,incSoln)
  nlines,L=opfdata.nlines,opfdata.L
  for l in L
    mpsoln.x_soln[l] = round(mpsoln.x_soln[l])
  end
  Xs = enumerate(feasXs)
  isNewX = true
  for (k,feasx) in Xs
    if sum( abs(mpsoln.x_soln[l]-feasx[2].x_soln[l]) for l=1:nlines ) < 1e-6
      isNewX=false
      break
    end
  end
  if isNewX
    pX = SolnInfo(zeros(nlines),ones(nlines),0.0,0.0)
    pX.x_soln .= mpsoln.x_soln
    pX.x_dualsoln .= mpsoln.x_dualsoln
    pX.optval = mpsoln.optval
    nXs = length(feasXs)+1
    feasXs[nXs]=pX
    if pX.optval > incSoln.optval
      incSoln.optval = pX.optval
      incSoln.x_soln .= pX.x_soln
      print("\t\t\tNew incumbent solution: ")
      printX(opfdata,incSoln.x_soln)
      print(" with value: $pVal")
    end
  end
end

testDualAC(opfdata)

#=
finalXSoln = SolnInfo(zeros(opfdata.nlines),ones(opfdata.nlines),0.0,0.0)

bestUBVal,nNodes,runtime = solveBnBSDP(opfdata,finalXSoln)

@printf("\n********************FINAL RESULT FOR CASE %s WITH %d LINES CUT H%dR%d*******************\n",CASE_NUM,K, HEUR,FORM)

@printf("Summary\t")
if(HEUR == 0 && FORM == AC)
    @printf("%d  &  ",K)
else
    @printf("    &   ")
end
if(FORM == AC )
    @printf("\$\\HSet^{%d}\$  &  ",HEUR)
else
    @printf("    &   ")
end

printResults=true
if printResults
if FORM == AC
    @printf("AC &    ")
elseif FORM == SDP
    @printf("SDP &    ")
elseif FORM == SOCP || FORM == SOCPBds
    @printf("SOCP &    ")
elseif FORM == DC
    @printf("DC &    ")
elseif FORM == ACSOC
    @printf("ACSOC &    ")
else
    println("Not implemented")
    printResults=false
end

#@printf("%d & ", ncuts)
#@printf("%.2f  & ", 100*time_Eta0SP/runtime)
@printf("%d &  ", nNodes)
@printf("%.2f &  ", runtime/nNodes)
#@printf("%d & ", ncuts)
# @printf("%d &   ", round(time_root-tShift))
#@printf("%d &  ", round(time_Eta0SP))
#@printf("%d &  ", round(total_TimeMP))
@printf("%d &  ", runtime)
printX(opfdata,finalXSoln.x_soln)
@printf(" & %.3f &  ", finalXSoln.optval)
if abs(bestUBVal-finalXSoln.optval) < 1e-3
  @printf("0.0\\%% &")
elseif finalXSoln.optval > 1e-3
  percentGap= 100*(bestUBVal-finalXSoln.optval)/finalXSoln.optval
  @printf("%.1f\\%% &",percentGap)
else
  print("---    & ")
end
  #@printf("\t&\t%.3f \t&\t%.3f\t & \t%.3f", optSDP, optSOCP, optDC)
@printf(" \\\\ \n")

println("No. Nodes: ", nNodes)
println("Best bound:  ", bestUBVal)
@printf("Objective value: %.3f\n", finalXSoln.optval)
@show runtime
@show finalXSoln
end
=#
