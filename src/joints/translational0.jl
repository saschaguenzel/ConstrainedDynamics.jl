@inline function getPositionDelta(joint::Translational0, body1::AbstractBody, body2::Body, x::SVector{3,T}) where T
    Δx = x # in body1 frame
    return Δx
end
@inline function getVelocityDelta(joint::Translational0, body1::AbstractBody, body2::Body, v::SVector{3,T}) where T
    Δv = v # in body1 frame
    return Δv
end

@inline function setForce!(joint::Translational2, body1::Body, body2::Body, F::SVector{3,T}) where T
    setForce!(joint, body1.state, body2.state, F)
    return
end
@inline function setForce!(joint::Translational2, body1::Origin, body2::Body, F::SVector{3,T}) where T
    setForce!(joint, body2.state, F)
    return
end

@inline function ∂Fτa∂u(joint::Translational0, body1::Body)
    return ∂Fτa∂u(joint, body1.state)
end
@inline function ∂Fτb∂u(joint::Translational0, body1::Body, body2::Body)
    if body2.id == joint.childid
        return ∂Fτb∂u(joint, body1.state, body2.state)
    else
        return ∂Fτb∂u(joint)
    end
end
@inline function ∂Fτb∂u(joint::Translational0, body1::Origin, body2::Body)
    if body2.id == joint.childid
        return return ∂Fτb∂u(joint, body2.state)
    else
        return ∂Fτb∂u(joint)
    end
end

@inline function minimalCoordinates(joint::Translational0, body1::Body, body2::Body)
    statea = body1.state
    stateb = body2.state
    return g(joint, statea.xc, statea.qc, stateb.xc, stateb.qc)
end
@inline function minimalCoordinates(joint::Translational0, body1::Origin, body2::Body)
    stateb = body2.state
    return g(joint, stateb.xc, stateb.qc)
end

@inline g(joint::Translational0, body1::AbstractBody, body2::AbstractBody, Δt) = g(joint)

@inline ∂g∂posa(joint::Translational0, body1::AbstractBody, body2::AbstractBody) = ∂g∂posa(joint)
@inline ∂g∂posb(joint::Translational0, body1::AbstractBody, body2::AbstractBody) = ∂g∂posb(joint)
@inline ∂g∂vela(joint::Translational0, body1::AbstractBody, body2::AbstractBody, Δt) = ∂g∂vela(joint)
@inline ∂g∂velb(joint::Translational0, body1::AbstractBody, body2::AbstractBody, Δt) = ∂g∂velb(joint)
