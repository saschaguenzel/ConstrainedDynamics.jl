mutable struct Mechanism{T,N,Ni}
    # tend::T
    # steps::Base.OneTo{Int64}
    origin::Origin{T}
    bodies::UnitDict{Base.OneTo{Int64},Body{T}}
    eqconstraints::UnitDict{UnitRange{Int64},<:EqualityConstraint{T}}
    ineqconstraints::UnitDict{UnitRange{Int64},<:InequalityConstraint{T}}

    graph::Graph{N}
    ldu::SparseLDU{T}
    # storage::Storage{T}

    # TODO remove once EqualityConstraint is homogenous
    normf::T
    normΔs::T

    Δt::T
    g::T
    No::Int64 # order of integrator

    α::T
    μ::T

    # shapes::Vector{<:Shape{T}}


    function Mechanism(origin::Origin{T},bodies::Vector{Body{T}},
        eqcs::Vector{<:EqualityConstraint{T}}, ineqcs::Vector{<:InequalityConstraint{T}};
        Δt::T = .01, g::T = -9.81, order = 1, shapes::Vector{<:Shape{T}} = Shape{T}[]) where T


        resetGlobalID()

        for body in bodies
            if norm(body.m)==0 || norm(body.J)==0
                @info "Potentially bad inertial properties detected"
            end 
        end

        Nb = length(bodies)
        Ne = length(eqcs)
        Ni = length(ineqcs)
        N = Nb + Ne
        # steps = Int64(ceil(tend / Δt))

        currentid = 1

        bdict = Dict{Int64,Int64}()
        for (ind, body) in enumerate(bodies)
            state = body.state
            state.order = order
            state.xk = [state.xk[1] for i = 1:order]
            state.qk = [state.qk[1] for i = 1:order]
            body.F = [body.F[1] for i = 1:order]
            body.τ = [body.τ[1] for i = 1:order]

            for eqc in eqcs
                eqc.pid == body.id && (eqc.pid = currentid)
                for (ind, bodyid) in enumerate(eqc.bodyids)
                    if bodyid == body.id
                        eqc.bodyids = setindex(eqc.bodyids, currentid, ind)
                        eqc.constraints[ind].cid = currentid
                    end
                end
            end

            for ineqc in ineqcs
                ineqc.pid == body.id && (ineqc.pid = currentid)
            end

            for shape in shapes
                for (i, id) in enumerate(shape.bodyids)
                    id == body.id && (shape.bodyids[i] = currentid)
                end
            end

            body.id = currentid
            currentid += 1

            bdict[body.id] = ind
        end

        eqdict = Dict{Int64,Int64}()
        for (ind, eqc) in enumerate(eqcs)
            eqc.id = currentid
            currentid += 1

            eqdict[eqc.id] = ind
        end

        ineqdict = Dict{Int64,Int64}()
        for (ind, ineqc) in enumerate(ineqcs)
            ineqc.id = currentid
            currentid += 1

            ineqdict[ineqc.id] = ind
        end

        normf = 0
        normΔs = 0

        graph = Graph(origin, bodies, eqcs, ineqcs)
        ldu = SparseLDU(graph, bodies, eqcs, ineqcs, bdict, eqdict, ineqdict)

        # storage = Storage{T}(steps, Nb, Ne)

        bodies = UnitDict(bodies)
        eqcs = UnitDict((eqcs[1].id):(eqcs[Ne].id), eqcs)
        if Ni > 0
            ineqcs = UnitDict((ineqcs[1].id):(ineqcs[Ni].id), ineqcs)
        else
            ineqcs = UnitDict(0:0, ineqcs)
        end

        α = 1
        μ = 1

        new{T,N,Ni}(origin, bodies, eqcs, ineqcs, graph, ldu, normf, normΔs, Δt, g, order, α, μ)
    end

    function Mechanism(origin::Origin{T},bodies::Vector{Body{T}},eqcs::Vector{<:EqualityConstraint{T}};
        Δt::T = .01, g::T = -9.81, order = 1, shapes::Vector{<:Shape{T}} = Shape{T}[]) where T

        ineqcs = InequalityConstraint{T}[]
        Mechanism(origin, bodies, eqcs, ineqcs, Δt = Δt, g = g, order = order, shapes = shapes)
    end

    function Mechanism(origin::Origin{T},bodies::Vector{Body{T}},ineqcs::Vector{<:InequalityConstraint{T}};
        Δt::T = .01, g::T = -9.81, order = 1, shapes::Vector{<:Shape{T}} = Shape{T}[]) where T

        eqc = EqualityConstraint{T}[]
        for body in bodies
            push!(eqc, EqualityConstraint(OriginConnection(origin, body)))
        end
        Mechanism(origin, bodies, eqc, ineqcs, Δt = Δt, g = g, order = order, shapes = shapes)
    end

    function Mechanism(origin::Origin{T},bodies::Vector{Body{T}};
        Δt::T = .01, g::T = -9.81, order = 1, shapes::Vector{<:Shape{T}} = Shape{T}[]) where T

        eqc = EqualityConstraint{T}[]
        for body in bodies
            push!(eqc, EqualityConstraint(OriginConnection(origin, body)))
        end
        Mechanism(origin, bodies, eqc, Δt = Δt, g = g, order = order, shapes = shapes)
    end

    function Mechanism(filename::AbstractString; floating::Bool=false, scalar_type::Type{T} = Float64, Δt::T = .01, g::T = -9.81, order::Integer = 1) where T
        origin, links, joints, shapes = parse_urdf(filename, T, floating)

        mechanism = Mechanism(origin, links, joints, shapes = shapes, Δt = Δt, g = g, order = order)

        graph = mechanism.graph
        xjointlist = Dict{Int64,SVector{3,T}}() # stores id, x in world frame
        qjointlist = Dict{Int64,Quaternion{T}}() # stores id, q in world frame

        for id in graph.rdfslist
            component = getcomponent(mechanism, id)
            if typeof(component) <: Body
                shape = getshape(shapes, id)

                body = component
                preds = predecessors(graph, id)
                @assert length(preds) == 1
                pid = preds[1]
                constraint = geteqconstraint(mechanism, pid)
                @assert length(constraint.constraints) == 2

                gpreds = predecessors(graph, pid)
                if length(gpreds) > 0 # predecessor is link
                    @assert length(gpreds) == 1
                    gpid = gpreds[1]

                    pbody = getbody(mechanism, gpid)
                    ggpreds = predecessors(graph, gpid)
                    @assert length(ggpreds) == 1
                    ggpid = ggpreds[1]
                    pconstraint = geteqconstraint(mechanism, ggpid)
                    @assert length(pconstraint.constraints) == 2

                    xpbody = pbody.state.xc
                    qpbody = pbody.state.qc

                    xpjointworld = xjointlist[pconstraint.id]
                    qpjointworld = qjointlist[pconstraint.id]
                else # predecessor is origin
                    pbody = origin

                    xpbody = SVector{3,T}(0, 0, 0)
                    qpbody = Quaternion{T}()

                    xpjointworld = SVector{3,T}(0, 0, 0)
                    qpjointworld = Quaternion{T}()
                end

                # urdf joint's x and q in parent's (pbody) frame
                xjoint = vrotate(xpjointworld + vrotate(constraint.constraints[1].vertices[1], qpjointworld) - xpbody, inv(qpbody))
                qjoint = qpbody \ qpjointworld * constraint.constraints[2].qoff

                # store joint's x and q in world frame
                xjointworld = xpbody + vrotate(xjoint, qpbody)
                qjointworld = qpbody * qjoint
                xjointlist[constraint.id] = xjointworld
                qjointlist[constraint.id] = qjointworld

                # difference to parent body (pbody)
                qbody = qjoint * body.state.qc

                # actual joint properties
                p1 = xjoint # in parent's (pbody) frame
                p2 = vrotate(-body.state.xc, inv(body.state.qc)) # in body frame (body.state.xc and body.state.qc are both relative to the same (joint) frame -> rotationg by inv(body.q) gives body frame)
                constraint.constraints[1].vertices = (p1, p2)

                V3 = vrotate(constraint.constraints[2].V3', qjoint) # in parent's (pbody) frame
                V12 = (svd(skew(V3)).Vt)[1:2,:]
                constraint.constraints[2].V3 = V3'
                constraint.constraints[2].V12 = V12
                constraint.constraints[2].qoff = qbody # in parent's (pbody) frame

                # actual body properties
                setPosition!(body) # set everything to zero
                setPosition!(pbody, body, p1 = p1, p2 = p2, Δq = qbody)

                # shape relative
                if shape !== nothing
                    shape.xoff = vrotate(xjointworld + vrotate(shape.xoff, qjointworld) - body.state.xc, inv(body.state.qc))
                    shape.qoff = qbody \ qjoint * shape.qoff
                end
            end
        end

        return mechanism, shapes
    end
end

function disassemble(mechanism::Mechanism{T}; shapes::Vector{<:Shape{T}} = Shape{T}[]) where T
    origin = mechanism.origin
    bodies = mechanism.bodies.values
    eqconstraints = mechanism.eqconstraints.values
    ineqconstraints = mechanism.ineqconstraints.values

    # Flip component ids
    for body in bodies
        body.id *= -1
    end
    for eqc in eqconstraints
        eqc.id *= -1
        if eqc.pid !== nothing
            eqc.pid *= -1
        end
        eqc.bodyids *= -1
    end
    for ineqc in ineqconstraints
        ineqc.id *= -1
        if ineqc.pid !== nothing
            ineqc.pid *= -1
        end
        ineqc.bodyids *= -1
    end
    for shape in shapes
        for (i,bodyid) in enumerate(shape.bodyids)
            if bodyid != origin.id 
                shape.bodyids[i] *= -1
            end
        end
    end

    # Set CURRENTID
    global CURRENTID = -1
    for body in bodies
        if body.id <= CURRENTID
            CURRENTID = body.id-1
        end
    end
    for eqc in eqconstraints
        if eqc.id <= CURRENTID
            CURRENTID = eqc.id-1
        end
    end
    for ineqc in ineqconstraints
        if ineqc.id <= CURRENTID
            CURRENTID = ineqc.id-1
        end
    end

    # Set origin to next id
    oldoid = origin.id
    origin.id = getGlobalID()
    for eqc in eqconstraints
        if eqc.pid === nothing
            eqc.pid = origin.id
        end
    end
    for ineqc in ineqconstraints
        if ineqc.pid == nothing
            ineqc.pid = origin.id
        end
    end
    for shape in shapes
        for (i,bodyid) in enumerate(shape.bodyids)
            if bodyid == oldoid 
                shape.bodyids[i] = origin.id
            end
        end
    end

    return origin, bodies, eqconstraints, ineqconstraints, shapes
end

function Base.show(io::IO, mime::MIME{Symbol("text/plain")}, M::Mechanism{T,N,0}) where {T,N}
    summary(io, M); println(io, " with ", length(M.bodies), " bodies and ", length(M.eqconstraints), " constraints")
end

function Base.show(io::IO, mime::MIME{Symbol("text/plain")}, M::Mechanism{T,N,Ni}) where {T,N,Ni}
    summary(io, M); println(io, " with ", length(M.bodies), " bodies, ", length(M.eqconstraints), " equality constraints, and ", Ni, " inequality constraints")
end
