
function parse_scalar(xel, name::String, ::Type{T}; default::String) where T 
    if xel != nothing
        return parse(T, attribute(xel, name))
    else
        return parse(T, default)
    end
end

# TODO: better handling of required attributes
function parse_vector(xel, name::String, ::Type{T}; default::String) where T
    if xel != nothing && attribute(xel, name) != nothing
        return [parse(T, str) for str in split(attribute(xel, name))]
    else
        return [parse(T, str) for str in split(default)]
    end
end

function parse_inertia_matrix(xinertia, ::Type{T}) where T
    if xinertia != nothing
        ixx = parse_scalar(xinertia, "ixx", T, default="0")
        ixy = parse_scalar(xinertia, "ixy", T, default="0")
        ixz = parse_scalar(xinertia, "ixz", T, default="0")
        iyy = parse_scalar(xinertia, "iyy", T, default="0")
        iyz = parse_scalar(xinertia, "iyz", T, default="0")
        izz = parse_scalar(xinertia, "izz", T, default="0")
        return [ixx ixy ixz; ixy iyy iyz; ixz iyz izz]
    else
        return zeros(T,3,3)
    end
end

function parse_pose(xpose, ::Type{T}) where T
    if xpose != nothing
        x = parse_vector(xpose, "xyz", T, default="0 0 0")
        rpy = parse_vector(xpose, "rpy", T, default="0 0 0")
        q = Quaternion(RotZYX(rpy[3], rpy[2], rpy[1]))
        return x, q
    else
        return zeros(T,3), Quaternion{T}()
    end
end

function parse_inertia(xinertial, T)
    x, q = parse_pose(find_element(xinertial, "origin"), T)
    inertia = parse_inertia_matrix(find_element(xinertial, "inertia"), T)
    mass = parse_scalar(find_element(xinertial, "mass"), "value", T, default="0")

    x, q, mass, inertia
end

function parse_shape(xvisual, T)
    xgeometry = find_element(xvisual, "geometry")
    @assert xgeometry!=nothing

    xmaterial = find_element(xvisual, "material")
    if xmaterial != nothing
        # colornode = child_nodes(xmaterial)
        # @assert length(colornode)==1
        colornode = find_element(xmaterial, "color")

        cvec = parse_vector(colornode, "rgba", T, default="0.5 0.5 0.5 1")
        color = RGBA(cvec[1:3]...)
    else
        color = RGBA(0.5, 0.5, 0.5)
    end

    # shapenode = child_nodes(xgeometry)
    # @assert length(shapenode)==1
    shapenode = find_element(xgeometry, "box")
    if shapenode != nothing
        xyz = parse_vector(shapenode, "size", T, default="1 1 1")
        return Box(xyz...,zero(T),color=color)
    else
        shapenode = find_element(xgeometry, "cylinder")
        if shapenode != nothing
            r = parse_scalar(shapenode, "radius", T, default="0.5")
            l = parse_scalar(shapenode, "length", T, default="1")
            
            return Cylinder(r,l,zero(T),color=color)
        else
            return nothing
        end
    end
end

function parse_link(xlink,::Type{T}) where T
    xinertial = find_element(xlink, "inertial")
    xvisual = find_element(xlink, "visual")
    if xinertial!=nothing
        x, q, mass, inertia = parse_inertia(xinertial, T)
    else
        x = zeros(T,3)
        q = Quaternion{T}()
        mass = zero(T)
        inertia = zeros(T,3,3)
    end
    
    name = attribute(xlink, "name")
    link = Body(mass, inertia)
    link.x[1] = x
    link.q[1] = q

    if xvisual!=nothing
        shape = parse_shape(xvisual, T)
    else
        shape = nothing
    end

    if shape != nothing
        push!(shape.bodyids, link.id)
    end

    return name, link, shape
end

function parse_links(xlinks,::Type{T}) where T
    ldict = Dict{String,MaximalCoordinateDynamics.AbstractBody{T}}()
    shapes = Shape{T}[]

    for xlink in xlinks
        name, link, shape = parse_link(xlink,T)
        ldict[name] = link
        shape != nothing && push!(shapes,shape)
    end

    return ldict, shapes
end

function parse_joint(xjoint, origin, plink, clink, ::Type{T}) where T
    joint_type = attribute(xjoint, "type")
    x, q = parse_pose(find_element(xjoint, "origin"), T)
    axis = parse_vector(find_element(xjoint, "axis"), "xyz", T, default="0 0 0")
    p1 = x
    p2 = clink.x[1]
    

    if joint_type == "revolute" || joint_type == "continuous"
        joint = EqualityConstraint(Revolute(plink, clink, p1, p2, axis))
    elseif joint_type == "prismatic"
        joint = EqualityConstraint(Prismatic(plink, clink, p1, p2, axis))
    elseif joint_type == "planar"
        joint = EqualityConstraint(Planar(plink, clink, p1, p2, axis))
    elseif joint_type == "fixed"
        joint = EqualityConstraint(Fixed(plink, clink))
    elseif joint_type == "floating"
        joint = EqualityConstraint(OriginConnection(origin, clink))
    end

    return x, q, joint
end

function parse_joints(xjoints,ldict)
    T = typeof(first(ldict).second.m)
    origins = Origin{T}[]
    links = Body{T}[]
    joints = EqualityConstraint{T}[]
    xlist = Vector{T}[]
    qlist = Quaternion{T}[]

    for name in keys(ldict)
        child = false
        for xjoint in xjoints
            xchild = find_element(xjoint, "child")
            childname = attribute(xchild, "link")
            if childname == name
                child = true
                break
            end
        end
        if child
            push!(links,ldict[name])
        else
            origin = Origin{T}()
            origin.id = ldict[name].id
            push!(origins,origin)
        end
    end

    @assert length(origins) == 1 "Multiple origins"

    origin = origins[1]

    for xjoint in xjoints
        xplink = find_element(xjoint, "parent")
        plink = ldict[attribute(xplink, "link")]
        if plink.id == origin.id
            plink = origin
        end
        xclink = find_element(xjoint, "child")
        clink = ldict[attribute(xclink, "link")]

        x, q, joint = parse_joint(xjoint, origin, plink, clink,T)
        push!(xlist,x)
        push!(qlist,q)
        push!(joints,joint)
    end

    return origin, links, joints
end