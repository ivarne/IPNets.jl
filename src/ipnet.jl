IPv4broadcast = reinterpret(UInt32, int32(-1))
IPv6broadcast = reinterpret(UInt128, int128(-1))

##################################################
# IP ADDRESS HANDLING OVERRIDES
##################################################
# constructor: ("1.2.3.4")
IPv4(ipstr::AbstractString) = parseipv4(ipstr)
IPv6(ipstr::AbstractString) = parseipv6(ipstr)

# Suppress leading '0's and "0x"
string_ipv6_field(field::UInt16) = return(hex(field))
string_ipv6_field(ip,i) = string_ipv6_field(ipv6_field(ip,i))


function string(ip::IPv6)
    i = 8
    m = 0
    str = ""
    longest_sub_i = -1
    while i!=0
        i-=1
        field = ipv6_field(ip,i)
        if field == 0 && longest_sub_i == -1
            # Find longest subsequence of 0
            longest_sub_i,j,m,c = i,i,1,1
            while j != 0
                j-=1
                if ipv6_field(ip,j) == 0
                    c += 1
                else
                    c = 0
                end
                if c > m
                    if j+c != longest_sub_i+1
                        longest_sub_i = j+c-1
                    end
                    m = c
                end
            end
            # Prevent single 0 from contracting to :: as required
            if m == 1
                longest_sub_i = 9
            end
        end
        if i == longest_sub_i
            str = string(str,":")
            i -= m-1
            if i == 0
                str = string(str,":")
                break
            end
        else
            if i != 7
                str = string(str,":")
            end
            str = string(str, string_ipv6_field(field))
        end
    end
    return str
end


function Base.isless(a::IPAddr, b::IPAddr)
    return isless(a.host, b.host)
end


##################################################
# IPNet
##################################################
width(::Type{IPv4}) = uint8(32)
width(::Type{IPv6}) = uint8(128)


function contiguousbitcount(n::Integer,t=UInt32)
    # takes an integer from 0 to 255 and a type, returns the number
    # of contiguous 1 bits in the number assuming it's of that type,
    # starting from the left.
    # cbc(240,UInt8) == 0x04 ("1111 0000")
    # cbc(252,UInt8) == 0x06 ("1111 1100")
    # cbc(127,UInt8) == error ("0111 1111")
    if sizeof(t) > 256
        error("input too large")
    else
        n = convert(t,n)
        invn = ~n
        bitct = log2(invn + 1)
        if !isinteger(bitct)
            error("noncontiguous bits")
        else
            return uint8(sizeof(t)*8 - int(bitct))
        end
    end
end


function mask2bits(t::Type, n::Unsigned)
    # takes a number of 1's bits in a
    # netmask and returns an integer representation
    maskbits = width(t)-n
    if maskbits < 0
        throw(BoundsError())
    end
    return (~(uint128(2)^maskbits-1))
end


##################################################
# Network representations
##################################################
abstract IPNet


function size(net::IPNet)
    numbits = width(typeof(net.netaddr)) - net.netmask
    return (big(2)^numbits, )
end


length(net::IPNet) = size(net)[1]


function string(net::IPNet)
    t = typeof(net)
    s = string("$t(\"")
    s = string(s, net.netaddr, "/", net.netmask, "\")")
    return s
end


function display(net::IPNet)
    print(string(net))
end


function show(io::IO, net::IPNet)
    print(io, string(net))
end


# IP Networks are ordered first by starting network address
# and then by network mask. That is, smaller IP nets (with higher
# netmask values) are "less" than larger ones. This corresponds
# to secondary reordering by ending address.
function isless(a::IPNet, b::IPNet)
    if a.netaddr == b.netaddr
        return isless(b.netmask, a.netmask)
    else
        return isless(a.netaddr, b.netaddr)
    end
end


function in(ipaddr::IPAddr, net::IPNet)
    netstart = net.netaddr.host
    numbits = width(typeof(ipaddr)) - net.netmask
    netend = net.netaddr.host + big(2)^numbits - 1
    return netstart <= ipaddr.host <= netend
end


function contains(net::IPNet, ipaddr::IPAddr)
    return in(ipaddr, net)
end


function getindex(net::IPNet, i::Integer)

    t = typeof(net.netaddr)
    ip = t(net.netaddr.host + i - 1)
    if !(ip in net)
        throw(BoundsError())
    else
        return ip
    end
end


# Vector look-alikes
endof(net::IPNet) = uint128(length(net))
minimum(net::IPNet) = net[1]
maximum(net::IPNet) = net[end]
extrema(net::IPNet) = (minimum(net), maximum(net))
getindex(net::IPNet, r::Range) = [net[i] for i in r]
getindex(net::IPNet, i::(Integer,)) = getindex(net,i[1])

##################################################
# IPv4
##################################################
immutable IPv4Net <: IPNet
    netaddr::IPv4
    netmask::UInt8
    function IPv4Net(na::IPv4, nmi::Integer)
        if !(0 <= nmi <= width(IPv4))
            error("Invalid netmask")
        else
            nm = uint8(nmi)
            mask = mask2bits(IPv4, nm)
            startip = uint32(na.host & mask)
            new(IPv4(startip),nm)
        end
    end
end


# "(x,y)"
IPv4Net{A,M}(tuple::(A,M)) = IPv4Net(tuple[1],tuple[2])


# "1.2.3.0/24"
function IPv4Net(ipmask::AbstractString)
    if search(ipmask,'/') > 0
        addrstr, netmaskstr = split(ipmask,"/")
        netmask = uint8(netmaskstr)
    else
        addrstr = ipmask
        netmask = width(IPv4)
    end
    netaddr = IPv4(addrstr)
    return IPv4Net(netaddr,netmask)
end


# "1.2.3.0", "255.255.255.0"
function IPv4Net(netaddr::AbstractString, netmask::AbstractString)
    netaddr = IPv4(netaddr).host
    netmask = contiguousbitcount(IPv4(netmask).host)
    return IPv4Net(netaddr, netmask)
end


# "1.2.3.0", 24
IPv4Net(netaddr::AbstractString, netmask::Integer) = IPv4Net(IPv4(netaddr), netmask)

# 123872, 24
IPv4Net(ipaddr::Integer, netmask::Integer) = IPv4Net(IPv4(ipaddr), netmask)

##################################################
# IPv6
##################################################
immutable IPv6Net <: IPNet
    # we treat the netmask as a potentially noncontiguous bitmask
    # for speed of calculation and consistency, but RFC2373, section
    # 2 provides for contiguous bitmasks only. We validate this
    # in the internal constructor. This wastes ~15 bytes per addr
    # for the benefit of rapid, consistent computation.
    netaddr::IPv6
    netmask::UInt32

    function IPv6Net(na::IPv6, nmi::Integer)
        if !(0 <= nmi <= width(IPv6))
            error("Invalid netmask")
        else
            nm = uint8(nmi)
            mask = mask2bits(IPv6, nm)
            startip = uint128(na.host & mask)
            return new(IPv6(startip), nm)
        end
    end
end


IPv6Net{T}(tuple::(T,T)) = IPv6Net(tuple[1],tuple[2])


# "2001::1/64"
function IPv6Net(ipmask::AbstractString)
    if search(ipmask,'/') > 0
        addrstr, netmaskbits = split(ipmask,"/")
        nmi = int(netmaskbits)
    else
        addrstr = ipmask
        netmaskint = width(IPv6)
    end
    netaddr = IPv6(addrstr)
    netmask = nmi
    return IPv6Net(netaddr,netmask)
end


# "2001::1", 64
function IPv6Net(netaddr::AbstractString, netmask::Integer)
    netaddr = IPv6(netaddr)
    return IPv6Net(netaddr, netmask)
end
