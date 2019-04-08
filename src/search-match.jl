#TODO:
#* optimization: try converting CartesianRange loops to array operations
#	* look up tensors for outer product style operations
#	* use e.g., sum(array, Dm+1:Dm+Df) to sum over female axes
#	* this might not produce a speedup though

using NLsolve
using QuantEcon: compute_fixed_point
using Distributions

const STDNORMAL = Normal()

### Helper functions ###

"Construct production array from function."
function prod_array(mtypes::Vector{Vector}, ftypes::Vector{Vector}, prodfn::Function)
	# get dimensions
	Dm = [length(v) for v in mtypes]
	Df = [length(v) for v in ftypes]

	# initialize arrays
	h = Array{Float64}(Dm..., Df...)
	gent = Vector{Float64}(length(mtypes)) # one man's vector of traits
	lady = Vector{Float64}(length(ftypes))

	for xy in CartesianRange(size(h))
		for trt in 1:length(mtypes) # loop through traits in xy
			gent[trt] = mtypes[trt][xy[trt]]
		end
		for trt in 1:length(ftypes) # loop through traits in xy
			lady[trt] = ftypes[trt][xy[trt+length(mtypes)]]
		end
		h[xy] = prodfn(gent, lady)
	end

	return h
end # prod_array

"Split vector `v` into male/female pieces, where `idx` is number of male types."
function sex_split(v::Vector, Dm::Tuple, Df::Tuple)
	idx = prod(Dm)
	vecm = v[1:idx]
	vecf = v[idx+1:end]
	return reshape(vecm, Dm), reshape(vecf, Df)
end

"Wrapper for nlsolve that handles the concatenation and splitting of sex-specific arrays."
function sex_solve(eqnsys!::Function, v_m::Array, v_f::Array)
	# initial guess: stacked vector of previous values
	guess = [vec(v_m); vec(v_f)]

	# NLsolve
	result = nlsolve(eqnsys!, guess)

	vm_new, vf_new = sex_split(result.zero, size(v_m), size(v_f))

	return vm_new, vf_new
end

"Outer product function for: (u_m * u_f) and (ψ_m + ψ_f)."
function outer_op(op::Function, men::Array, wom::Array)
	out = Array{Float64}(size(men)...,size(wom)...) # assumes 3+3 dims
	for xy in CartesianRange(size(out))
		x = xy.I[1:3]
		y = xy.I[4:6]
		out[xy] = op(men[x...], wom[y...]) # apply operator
	end
	return out
end


"""
	SearchMatch(λ, δ, r, σ, θ_m, θ_f, γ_m, γ_f, ψ_m, ψ_f, ℓ_m, ℓ_f, h;
	            β=0.5, CRS=false, verbose=false, step_size=0.2)

Construct a Shimer & Smith (2000) marriage market model and solve for the equilibrium.
When match-specific shocks are included, the divorce process is endogenized as in Goussé (2014).

The equilibrium is the solution to a nested fixed-point mapping.
The inner fixed-point solves for a matching equilibrium: consistent strategies given fixed
singles densities.
The outer fixed-point solves for a market equilibrium: singles densities that are consistent
with strategies.

Model selection depends which arguments are provided:
* Match-specific additive shocks ``z ~ N(0, σ)`` when ``σ > 0``
	* Note: some randomness is required for the fixed point iteration to converge with sex asymmetry
* Closed system or inflow/outflow:
	* `ℓ_m, ℓ_f` exogenous: population circulates between singlehood and marriage, no birth/death
	* Death rates `ψ_m, ψ_f`, inflows `γ_m, γ_f`: population distributions `ℓ_m, ℓ_f` endogenous
* Matching technology: quadratic by default unless `CRS=true`
"""
struct SearchMatch # struct is immutable

	### Parameters ###

	"arrival rate of meetings"
	λ::Real
	"arrival rate of separation shocks"
	δ::Real
	"discount rate"
	r::Real
	"standard deviation of normally distributed match-specific additive shock"
	σ::Real
	"Nash bargaining weight of wife"
	β::Real

	### Exogenous objects ###
	"male type space"
	θ_m::Vector{Vector}
	"female type space"
	θ_f::Vector{Vector}
	"male inflows by type"
	γ_m::Array
	"female inflows by type"
	γ_f::Array

	"arrival rates of male death by type"
	ψ_m::Array
	"arrival rates of female death by type"
	ψ_f::Array

	"production function as array"
	h::Array

	### Endogenous equilibrium objects ###

	"male population distribution: not normalized"
	ℓ_m::Array
	"female population distribution: not normalized"
	ℓ_f::Array

	"mass of single males"
	u_m::Array
	"mass of single females"
	u_f::Array

	"male singlehood (average) value function as vector"
	v_m::Array
	"female singlehood (average) value function as vector"
	v_f::Array

	"match function as array"
	α::Array

	"marital (average) surplus function as array"
	s::Array


	### Inner Constructor ###

	"""
	Inner constructor that accomodates several model variants, depending on the arguments provided.
	It is not meant to be called directly -- instead, outer constructors should call this
	constructor with a full set of arguments, using zero values for unwanted components.
	"""
	function SearchMatch(λ::Real, δ::Real, r::Real, σ::Real, θ_m::Vector{Vector}, θ_f::Vector{Vector},
	                     γ_m::Array, γ_f::Array, ψ_m::Array, ψ_f::Array,
	                     ℓ_m::Array, ℓ_f::Array, h::Array;
	                     β=0.5, CRS=false, verbose=false, step_size=0.2)

		### Model Selection ###

		# dimensions of type spaces as tuples
		D_m = ([length(v) for v in θ_m]...)
		D_f = ([length(v) for v in θ_f]...)

		# total numbers of types
		N_m = prod(D_m)
		N_f = prod(D_f)

		if sum(ψ_m) > 0 && sum(ψ_f) > 0 # inflow/outflow model: if death rates provided
			INFLOW = true
		else
			INFLOW = false
		end

		if σ == 0
			STOCH = false
			step_size = 1 # don't shrink fixed point iteration steps
		else
			STOCH = true
		end


		### Argument Validation ###

		if any([λ, δ, r] .≤ 0)
			error("Parameters λ, δ, r must be positive.")
		elseif !(size(ψ_m) == size(γ_m) == size(ℓ_m))
			error("Dimension mismatch: males.")
		elseif !(size(ψ_f) == size(γ_f) == size(ℓ_f))
			error("Dimension mismatch: females.")
		elseif D_m ≠ size(γ_m)
			error("Dimension mismatch: males.")
		elseif D_f ≠ size(γ_f)
			error("Dimension mismatch: females.")
		end

		if INFLOW # birth/death model
			if any(ℓ_m .> 0) || any(ℓ_f .> 0)
				error("Death rate ψ provided: population distributions ℓ_m, ℓ_f are endogenous.")
			elseif sum(γ_m) ≤ 0 || sum(γ_f) ≤ 0
				error("Total population inflow must be positive.")
			elseif any(ψ_m .< 0) || any(ψ_f .< 0)
				error("Death rates must be non-negative.")
			end
		else # closed system: population exogenous
			if sum(ℓ_m) ≤ 0 || sum(ℓ_f) ≤ 0
				error("No death: population must be positive.")
			elseif any(ℓ_m .< 0) || any(ℓ_f .< 0)
				error("Population masses must be non-negative.")
			end
		end

		if STOCH && σ < 0
			error("σ must be non-negative.")
		end


		### Compute Constants and Define Functions ###

		if INFLOW
			# population size given directly by inflow and outflow rates
			ℓ_m = γ_m ./ ψ_m
			ℓ_f = γ_f ./ ψ_f
		end

		"μ function, using inverse Mills ratio: E[z|z>q] = σ ϕ(q/σ) / (1 - Φ(q/σ))."
		function μ(a::Real)
			st = quantile(STDNORMAL, 1-a) # pre-compute -s/σ = Φ^{-1}(1-a)
			return σ * (pdf(STDNORMAL, st) - a * st)
		end

		"cdf of match-specific marital productivity shocks"
		G(x::Real) = STOCH ? cdf(Normal(0, σ), x) : Float64(x ≥ 0) # bool as float

		"Compute average match surplus array ``s(x,y)`` from value functions."
		function match_surplus(v_m::Array, v_f::Array, A::Array)
			s = similar(h)
			for xy in CartesianRange(size(s))
				x = xy.I[1:length(D_m)]
				y = xy.I[length(D_m)+1:end]
				if STOCH
					s[xy] = h[xy] - v_m[x...] - v_f[y...] +
					            δ * μ(A[xy]) / (r + δ + ψ_m[x...] + ψ_f[y...])
				else # deterministic Shimer-Smith model
					s[xy] = h[xy] - v_m[x...] - v_f[y...]
				end
			end
			return s
		end

		"""
		Update matching function ``α(x,y)`` from ``S ≥ 0`` condition.

		When `G` is degenerate, this yields the non-random case.
		"""
		function update_match(v_m::Array, v_f::Array, A::Array)
			return 1 - G.(-match_surplus(v_m, v_f, A)) # in deterministic case, G is indicator function
		end

		#ψm_ψf = outer_op(+, ψ_m, ψ_f) # outer sum array for efficient array operations


		### Steady-State Equilibrium Conditions ###
		"""
		Update population distributions.

		Compute the implied singles distributions given a matching function.
		The steady state conditions equating flows into and out of marriage
		in the deterministic setting are
		```math
		∀x, (δ + ψ(x))(ℓ(x) - u(x)) = λ u(x) ∫ α(x,y) u(y) dy
		```
		and with productivity shocks and endogenous divorce they are
		```math
		∀x, ℓ(x) - u(x) = λ u(x) ∫\frac{α(x,y)}{ψ(x)+ψ(y)+δ(1-α(x,y))}u(y)dy
		```
		Thus, this function solves a non-linear system of equations for `u_m` and `u_f`.
		The constraints ``0 ≤ u ≤ ℓ`` are not enforced here, but the outputs of this function
		are truncated in the fixed point iteration loop.
		"""
		function steadystate!(u::Vector, res::Vector, α::Array)# stacked vector

			# initialize arrays
			mres = similar(ℓ_m)
			fres = similar(ℓ_f)

			u_m, u_f = sex_split(u, D_m, D_f) # reconstitute arrays from stacked vector

			if CRS # matching technology
				UmUf = sqrt(sum(u_m) * sum(u_f))
			else # quadratic
				UmUf = 1
			end

			if STOCH
				# compute residuals of non-linear system
				for x in CartesianRange(D_m)
					mres[x] = ℓ_m[x] - u_m[x] * (1 + λ / UmUf
					                             * sum(α[x.I...,y.I...] * u_f[y]
					                                   / (δ * (1 - α[x.I...,y.I...]) + ψ_m[x] + ψ_f[y])
					                                   for y in CartesianRange(D_f)))
				end
				for y in CartesianRange(D_f)
					fres[y] = ℓ_f[y] - u_f[y] * (1 + λ / UmUf
					                             * sum(α[x.I...,y.I...] * u_m[x]
					                                   / (δ * (1 - α[x.I...,y.I...]) + ψ_m[x] + ψ_f[y])
					                                   for x in CartesianRange(D_m)))
				end
			else # deterministic case
				for x in CartesianRange(D_m)
					mres[x] = (δ + ψ_m[x]) * ℓ_m[x] - u_m[x] * ((δ + ψ_m[x]) + λ / UmUf
					            * sum(α[x.I...,y.I...] * u_f[y] for y in CartesianRange(D_f)))
				end
				for y in CartesianRange(D_f)
					fres[y] = (δ + ψ_f[y]) * ℓ_f[y] - u_f[y] * ((δ + ψ_f[y]) + λ / UmUf
					            * sum(α[x.I...,y.I...] * u_m[x] for x in CartesianRange(D_m)))
				end
			end

			res[:] = [vec(mres); vec(fres)] # concatenate into stacked vector
		end # steadystate!


		"""
		Update singlehood value functions for deterministic case only.

		Compute the implied singlehood value functions given a matching function
		and singles distributions.
		```math
		∀x, v(x) = (1-β) λ ∫ α(x,y) S(x,y) u(y) dy
		```
		This function solves a non-linear system of equations for the average value
		functions, `v(x) = (r+ψ(x))V(x)`.
		"""
		function valuefunc_base!(v::Vector, res::Vector, u_m::Array, u_f::Array, A::Array)
			vm, vf = sex_split(v, D_m, D_f) # reconstitute arrays from stacked vector

			if CRS # matching technology
				UmUf = sqrt(sum(u_m) * sum(u_f))
			else # quadratic
				UmUf = 1
			end

			# initialize arrays
			mres = similar(ℓ_m)
			fres = similar(ℓ_f)

			# precompute the fixed weights
			αs = A .* match_surplus(vm, vf, A)

			# compute residuals of non-linear system
			for x in CartesianRange(D_m)
				mres[x] = (vm[x] - (1-β) * λ / UmUf
				           * sum(αs[x.I...,y.I...] / (r + δ + ψ_m[x] + ψ_f[y]) * u_f[y]
				                 for y in CartesianRange(D_f)))
			end
			for y in CartesianRange(D_f)
				fres[y] = (vf[y] - β * λ / UmUf
				           * sum(αs[x.I...,y.I...] / (r + δ + ψ_m[x] + ψ_f[y]) * u_m[x]
				                 for x in CartesianRange(D_m)))
			end

			res[:] = [vec(mres); vec(fres)] # concatenate into stacked vector
		end # valuefunc_base!


		### Equilibrium Solver ###

		# Initialize guesses for v (deterministic case only): overwritten and reused
		#   in the inner fixed point iteration.
		v_m = ones(Float64, D_m)
		v_f = ones(Float64, D_f)

		# rough initial guess (one-dimensional case)
		#v_m = 0.5 * h[:,1]
		#v_f = 0.5 * h[1,:]

		# Initialize matching array: overwritten and reused in the outer fixed point iteration
		α = 0.05 * ones(Float64, size(h))

		# rough initial guess for positive assortativity (one-dimensional case)
		#for i in 1:N_m, j in 1:N_f
		#	α[i,j] = 1/(1 + exp(abs(i-j)/10))
		#end

		"""
		Matching equilibrium fixed point operator ``T_α(α)``.
		Solves value functions and match probabilities given singles distributions.
		The value functional equations are:
		```math
		∀x, (r+ψ(x))V(x) = (1-β) λ ∫\frac{μ(α(x,y))}{r+δ+ψ(x)+ψ(y)}u(y)dy,\\
		μ(α(x,y)) = α(x,y)(-G^{-1}(1-α(x,y)) + E[z|z > G^{-1}(1-α(x,y))])
		```
		Alternatively, this could be written as an array of point-wise equations
		and solved for α.

		They keyword argument `step_size` controls the step size of the fixed point iteration.
		Steps must be shrunk or else the iterates can get stuck in an oscillating pattern.
		"""
		function fp_matching_eqm(A::Array, u_m::Array, u_f::Array)
			# overwrite v_m, v_f to reuse as initial guess for nlsolve
			if STOCH
				if CRS # matching technology
					UmUf = sqrt(sum(u_m) * sum(u_f))
				else # quadratic
					UmUf = 1
				end

				μα = μ.(A) # precompute μ term

				# compute residuals of non-linear system
				for x in CartesianRange(D_m)
					v_m[x] = (1-β) * λ / UmUf * sum(μα[x.I...,y.I...] / (r + δ + ψ_m[x] + ψ_f[y]) * u_f[y]
					                                for y in CartesianRange(D_f))
				end
				for y in CartesianRange(D_f)
					v_f[y] = β * λ / UmUf * sum(μα[x.I...,y.I...] / (r + δ + ψ_m[x] + ψ_f[y]) * u_m[x]
					                            for x in CartesianRange(D_m))
				end

			else # need to solve non-linear system because α no longer encodes s
				v_m[:], v_f[:] = sex_solve((v,res)->valuefunc_base!(v, res, u_m, u_f, A), v_m, v_f)
			end

			# shrink update step size
			return (1-step_size) * A + step_size * update_match(v_m, v_f, A)
		end

		"""
		Market equilibrium fixed point operator ``T_u(u_m, u_f)``.
		Solves for steady state equilibrium singles distributions, with strategies
		forming a matching equilibrium.
		"""
		function fp_market_eqm(u::Vector; inner_tol=1e-4)

			um, uf = sex_split(u, D_m, D_f)

			# nested fixed point: overwrite α to be reused as initial guess for next call
			α[:] = compute_fixed_point(a->fp_matching_eqm(a, um, uf), α,
			                           err_tol=inner_tol, max_iter=1000, verbose=verbose)

			# steady state distributions
			um_new, uf_new = sex_solve((xm,yf)->steadystate!(xm,yf,α), um, uf)

			# truncate if `u` strays out of bounds
			if minimum([vec(um_new); vec(uf_new)]) < 0
				warn("u negative: truncating...")
			elseif minimum([vec(ℓ_m - um_new); vec(ℓ_f - uf_new)]) < 0
				warn("u > ℓ: truncating...")
			end
			um_new[:] = clamp.(um_new, 0, ℓ_m)
			uf_new[:] = clamp.(uf_new, 0, ℓ_f)

			return [vec(um_new); vec(uf_new)]
		end

		# Solve fixed point

		# fast rough compututation of equilibrium by fixed point iteration
		u_fp0 = compute_fixed_point(fp_market_eqm, 0.15*[vec(ℓ_m); vec(ℓ_f)],
		                            print_skip=10, verbose=1+verbose) # initial guess u = 0.1*ℓ

		um_0, uf_0 = sex_split(u_fp0, D_m, D_f)

		# touch up with high precision fixed point solution
		u_fp = compute_fixed_point(u->fp_market_eqm(u, inner_tol=1e-8), [vec(um_0); vec(uf_0)],
		                           err_tol=1e-8, verbose=1+verbose)
		
		u_m, u_f = sex_split(u_fp, D_m, D_f)

		s = match_surplus(v_m, v_f, α)

		# construct instance
		new(λ, δ, r, σ, β, θ_m, θ_f, γ_m, γ_f, ψ_m, ψ_f, h, ℓ_m, ℓ_f, u_m, u_f, v_m, v_f, α, s)

	end # constructor

end # struct


### Outer Constructors ###

# Recall inner constructor:
#	SearchMatch(λ, δ, r, σ, θ_m, θ_f, γ_m, γ_f, ψ_m, ψ_f, ℓ_m, ℓ_f, h; β=0.5, CRS=false, verbose=false, step_size=0.2)

"""
Outer constructor that constructs the production array from the types and production function.
"""
function SearchMatch(λ::Real, δ::Real, r::Real, σ::Real, θ_m::Vector{Vector}, θ_f::Vector{Vector},
                     γ_m::Array, γ_f::Array, ψ_m::Array, ψ_f::Array,
                     ℓ_m::Array, ℓ_f::Array, g::Function;
                     β=0.5, CRS=false, verbose=false, step_size=0.2)

	# construct production array
	h = prod_array(θ_m, θ_f, g)

	return SearchMatch(λ, δ, r, σ, θ_m, θ_f, γ_m, γ_f, ψ_m, ψ_f, ℓ_m, ℓ_f, h;
	                   β=β, CRS=CRS, verbose=verbose, step_size=step_size)
end


### Convenience methods to call constructors ###

"""
	SearchClosed(λ, δ, r, σ, θ_m, θ_f, ℓ_m, ℓ_f, g; β=0.5, CRS=false, verbose=false, step_size=0.2)

Constructs marriage market equilibrium of closed-system model with match-specific productivity shocks and production function ``g(x,y)``.
"""
function SearchClosed(λ::Real, δ::Real, r::Real, σ::Real,
                      θ_m::Vector{Vector}, θ_f::Vector{Vector}, ℓ_m::Array, ℓ_f::Array,
                      g::Function; β=0.5, CRS=false, verbose=false, step_size=0.2)
	# irrelevant arguments to pass as zeros
	ψ_m = zeros(ℓ_m)
	ψ_f = zeros(ℓ_f)
	γ_m = zeros(ℓ_m)
	γ_f = zeros(ℓ_f)

	return SearchMatch(λ, δ, r, σ, θ_m, θ_f, γ_m, γ_f, ψ_m, ψ_f, ℓ_m, ℓ_f, g;
	                   β=β, CRS=CRS, verbose=verbose, step_size=step_size)
end

"""
	SearchClosed(λ, δ, r, σ, θ_m, θ_f, ℓ_m, ℓ_f, g; β=0.5, CRS=false, verbose=false, step_size=0.2)

Method for one-dimensional types.
"""
function SearchClosed(λ::Real, δ::Real, r::Real, σ::Real,
                      θ_m::Vector, θ_f::Vector, ℓ_m::Array, ℓ_f::Array,
                      g::Function; β=0.5, CRS=false, verbose=false, step_size=0.2)
	# augment production function
	gg(x::Array, y::Array) = g(x[1], y[1])

	return SearchClosed(λ, δ, r, σ, Vector[θ_m], Vector[θ_f], ℓ_m, ℓ_f, gg;
	                    β=β, CRS=CRS, verbose=verbose, step_size=step_size)
end

"""
	SearchInflow(λ, δ, r, σ, θ_m, θ_f, γ_m, γ_f, ψ_m, ψ_f, g; β=0.5, CRS=false, verbose=false, step_size=0.2)

Constructs marriage market equilibrium of inflow and death model with match-specific productivity shocks and production function ``g(x,y)``.
"""
function SearchInflow(λ::Real, δ::Real, r::Real, σ::Real,
                      θ_m::Vector{Vector}, θ_f::Vector{Vector}, γ_m::Array, γ_f::Array,
                      ψ_m::Array, ψ_f::Array, g::Function;
                      β=0.5, CRS=false, verbose=false, step_size=0.2)
	# irrelevant arguments to pass as zeros
	ℓ_m = zeros(γ_m)
	ℓ_f = zeros(γ_f)

	return SearchMatch(λ, δ, r, σ, θ_m, θ_f, γ_m, γ_f, ψ_m, ψ_f, ℓ_m, ℓ_f, g;
	                   β=β, CRS=CRS, verbose=verbose, step_size=step_size)
end

"""
	SearchInflow(λ, δ, r, σ, θ_m, θ_f, γ_m, γ_f, ψ_m, ψ_f, g; β=0.5, CRS=false, verbose=false, step_size=0.2)

Method for one-dimensional types.
"""
function SearchInflow(λ::Real, δ::Real, r::Real, σ::Real,
                      θ_m::Vector, θ_f::Vector, γ_m::Array, γ_f::Array,
                      ψ_m::Array, ψ_f::Array, g::Function;
                      β=0.5, CRS=false, verbose=false, step_size=0.2)
	# augment production function
	gg(x::Array, y::Array) = g(x[1], y[1])

	return SearchInflow(λ, δ, r, σ, Vector[θ_m], Vector[θ_f], γ_m, γ_f, ψ_m, ψ_f, gg;
	                    β=β, CRS=CRS, verbose=verbose, step_size=step_size)
end
