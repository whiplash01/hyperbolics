using PyCall
using Pandas
using ArgParse

@pyimport numpy as np
@pyimport networkx as nx
@pyimport scipy.sparse.csgraph as csg
unshift!(PyVector(pyimport("sys")["path"]), "")
unshift!(PyVector(pyimport("sys")["path"]), "hMDS")
@pyimport utils.load_graph as lg
@pyimport utils.distortions as dis
@pyimport utils.load_dist as ld

# Parse command line arguments
function parse_commandline()
    s = ArgParseSettings()
    @add_arg_table s begin
        "--dataset", "-d"
            help = "Dataset to embed"
            required = true
        "--dim", "-r"
            help = "Dimension r"
            arg_type = Int32
            required = true
        "--scale", "-t"
            arg_type = Float64
            help = "Scaling factor"
            required = true
        "--save-embedding", "-m"
            help = "Save embedding to file"
        "--procs", "-q"
            help = "Number of processes to use"
            arg_type = Int64
            default = 1
    end
    return parse_args(s)
end

function gans_to_poincare(X)
    _,n = size(X)
    for i=1:n
        nr = 1.0+sqrt.(1.0+norm(X[:,i])^2)
        X[:,i] /= nr
    end
    return
end

function power_method(A,d,tol;verbose=false, T=1000)
    (n,n) = size(A)
    x_all = qr(randn(n,d))[1]
    _eig  = zeros(d)
    if verbose
        println("\t\t Entering Power Method $(d) $(tol) $(T) $(n)")
    end
    for j=1:d
        if verbose tic() end
        x = view(x_all,:,j)
        x /= norm(x)
        for t=1:T            
            x = A*x
            if j > 1
                #x -= sum(x_all[:,1:(j-1)]*diagm(,2)
                yy = vec(x'view(x_all, :,1:(j-1)))
                for k=1:(j-1)
                    x -= view(x_all,:,k)*yy[k]
                end
            end
            nx = norm(x)
            x /= nx
            cur_dist = abs(nx - _eig[j])
            if !isinf(cur_dist) &&  min(cur_dist, cur_dist/nx) < tol
                if verbose
                    println("\t Done with eigenvalue $(j) at iteration $(t) at abs_tol=$(Float64(abs(nx - _eig[j]))) rel_tol=$(Float64(abs(nx - _eig[j])/nx))")
                end
                if verbose toc() end
                break
            end
            if t % 500 == 0 && verbose
                println("\t $(t) $(cur_dist)\n\t\t $(cur_dist/nx)")
            end 
            _eig[j]    = nx
        end
        x_all[:,j] = x 
    end
    return (_eig, x_all)
end

function power_method_sign(A,r,tol;verbose=false, T=1000)
    _d, _U    = power_method(A'A,r, tol;T=T)
    X         = _U'A*_U 
    _d_signed = vec(diag(X))
    if verbose
        print("Log Off Diagonals: $( Float64(log(vecnorm( X - diagm(_d_signed)))))")
    end
    return _d_signed, _U
end

# hMDS with one PCA call
function h_mds(Z, k, n, tol)
    # run PCA on -Z
    tic()
    lambdasM, usM = power_method_sign(-Z,k,tol) 
    lambdasM_pos = copy(lambdasM)
    usM_pos = copy(usM)
    
    idx = 0
    for i in 1:k
        if lambdasM[i] > 0
            idx += 1
            lambdasM_pos[idx] = lambdasM[i]
            usM_pos[:,idx] = usM[:,i]
        end
    end
    
    Xrec = usM_pos[:,1:idx] * diagm(lambdasM_pos[1:idx].^ 0.5);
    toc()
    
    return Xrec', idx
end

parsed_args = parse_commandline()
println("\n=============================")
println("h-MDS. Info:")
println("Data set = $(parsed_args["dataset"])")
println("Dimensions = $(parsed_args["dim"])")

if parsed_args["save-embedding"] == nothing
    println("No file specified to save embedding!")
else
    println("Save embedding to $(parsed_args["save-embedding"])")
end

k     = parsed_args["dim"]
scale = parsed_args["scale"]
tol   = 1e-8

println("Scaling = $(convert(Float64,scale))\n");

G = lg.load_graph(parsed_args["dataset"])
H = ld.get_dist_mat(G);
n,_ = size(H)

BLAS.set_num_threads(parsed_args["procs"]) # HACK

# used for new simplified hMDS
Y = cosh.(H*scale)

println("Doing h-MDS...")
tic()
# this is a Gans model set of points
Xrec, found_dimension = h_mds(Y, k, n, tol)

# convert from Gans to Poincare ball model
gans_to_poincare(Xrec)
toc()

# save the recovered points:
if parsed_args["save-embedding"] != nothing
    df = DataFrame(Xrec)

    # save scale also:
    df["scale"] = scale
    to_csv(df, parsed_args["save-embedding"])
end

if found_dimension > 1
    println("Building recovered graph...")
    tic()
    Zrec = zeros(n, n)
    Threads.@threads for i = 1:n
        for j = 1:n
            Zrec[i,j] = norm(Xrec[:,i] - Xrec[:,j])^2 / ((1 - norm(Xrec[:,i])^2) * (1 - norm(Xrec[:,j])^2));
        end
    end
    toc()
    
    println("Getting metrics...")
    tic()
    Hrec = acosh.(1+2*Zrec)
    Hrec /= scale        
     
    mc, me, dist, bad = dis.distortion(H, Hrec, n, 1)
    println("\nDistortion avg, max, bad = $(convert(Float64,dist)), $(convert(Float64,mc*me)), $(convert(Float64,bad))")  
    mapscore = dis.map_score(H, Hrec, n, 1)
    println("MAP = $(mapscore)")   
    #println("Dimension = $(found_dimension)")     
else
    println("Dimension = 1!")
end

