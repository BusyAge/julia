module Pkg2

include("pkg2/dir.jl")
include("pkg2/types.jl")
include("pkg2/reqs.jl")
include("pkg2/cache.jl")
include("pkg2/read.jl")
include("pkg2/query.jl")
include("pkg2/resolve.jl")
include("pkg2/write.jl")

using Base.Git, .Types

rm(pkg::String) = edit(Reqs.rm, pkg)
add(pkg::String, vers::VersionSet) = edit(Reqs.add, pkg, vers)
add(pkg::String, vers::VersionNumber...) = add(pkg, VersionSet(vers...))
init(meta::String=Dir.DEFAULT_META) = Dir.init(meta)

edit(f::Function, pkg, args...) = Dir.cd() do
    r = Reqs.read("REQUIRE")
    reqs = Reqs.parse(r)
    avail = Read.available()
    if !haskey(avail,pkg) && !haskey(reqs,pkg)
        error("unknown package $pkg")
    end
    r_ = f(r,pkg,args...)
    r_ == r && return info("Nothing to be done.")
    reqs_ = Reqs.parse(r_)
    reqs_ != reqs && resolve(reqs_,avail)
    Reqs.write("REQUIRE",r_)
    info("REQUIRE updated.")
end

urlpkg(url::String) = match(r"/(\w+?)(?:\.jl)?(?:\.git)?$/*", url).captures[1]

clone(url::String, pkg::String=urlpkg(url); opts::Cmd=``) = Dir.cd() do
    ispath(pkg) && error("$pkg already exists")
    try Git.run(`clone $opts $url $pkg`)
    catch
        run(`rm -rf $pkg`)
        rethrow()
    end
    isempty(Reqs.parse("$pkg/REQUIRE")) && return
    info("Computing changes...")
    resolve()
end

update() = Dir.cd() do
    info("Updating METADATA...")
    cd("METADATA") do
        if Git.branch() != "devel"
            Git.run(`fetch -q --all`)
            Git.run(`checkout -q HEAD^0`)
            Git.run(`branch -f devel refs/remotes/origin/devel`)
            Git.run(`checkout -q devel`)
        end
        Git.run(`pull -q`)
    end
    avail = Read.available()
    # this has to happen before computing free/fixed
    for pkg in filter!(Read.isinstalled,[keys(avail)...])
        Cache.prefetch(pkg, Read.url(pkg), [a.sha1 for (v,a)=avail[pkg]])
    end
    instd = Read.installed(avail)
    free = Read.free(instd)
    for (pkg,ver) in free
        Cache.prefetch(pkg, Read.url(pkg), [a.sha1 for (v,a)=avail[pkg]])
    end
    fixed = Read.fixed(avail,instd)
    for (pkg,ver) in fixed
        ispath(pkg,".git") || continue
        if Git.attached(dir=pkg) && !Git.dirty(dir=pkg)
            info("Updating $pkg...")
            @recover begin
                Git.run(`fetch -q --all`, dir=pkg)
                Git.run(`pull -q`, dir=pkg)
            end
        end
        if haskey(avail,pkg)
            Cache.prefetch(pkg, Read.url(pkg), [a.sha1 for (v,a)=avail[pkg]])
        end
    end
    info("Computing changes...")
    resolve(Reqs.parse("REQUIRE"), avail, instd, fixed, free)
end

resolve(
    reqs  :: Dict,
    avail :: Dict = Dir.cd(Read.available),
    instd :: Dict = Dir.cd(()->Read.installed(avail)),
    fixed :: Dict = Dir.cd(()->Read.fixed(avail,instd)),
    have  :: Dict = Dir.cd(()->Read.free(instd))
) = Dir.cd() do

    reqs = Query.requirements(reqs,fixed)
    deps = Query.dependencies(avail,fixed)

    for pkg in keys(reqs)
        haskey(deps, pkg) ||
            error("$pkg has no version compatible with fixed requirements")
    end

    want = Resolve.resolve(reqs,deps)

    # compare what is installed with what should be
    install, update, remove = Query.diff(have, want)
    if isempty(install) && isempty(update) && isempty(remove)
        return info("No packages to install, update or remove.")
    end

    # prefetch phase isolates network activity, nothing to roll back
    missing = {}
    for (pkg,ver) in install
        append!(missing,
            map(sha1->(pkg,ver,sha1),
                Cache.prefetch(pkg, Read.url(pkg), Read.sha1(pkg,ver))))
    end
    for (pkg,(_,ver)) in update
        append!(missing,
            map(sha1->(pkg,ver,sha1),
                Cache.prefetch(pkg, Read.url(pkg), Git.head(dir=pkg), Read.sha1(pkg,ver))))
    end
    for (pkg,ver) in remove
        append!(missing,
            map(sha1->(pkg,ver,sha1),
                Cache.prefetch(pkg, Read.url(pkg), Git.head(dir=pkg))))
    end
    if !isempty(missing)
        msg = "unfound package versions (possible metadata misconfiguration):"
        for (pkg,ver,sha1) in missing
            msg *= "  $pkg v$ver [$sha1[1:10]]\n"
        end
        error(msg)
    end

    # try applying changes, roll back everything if anything fails
    installed, updated, removed = {}, {}, {}
    try
        for (pkg,ver) in install
            info("Installing $pkg v$ver")
            Write.install(pkg, Read.sha1(pkg,ver))
            push!(installed,(pkg,ver))
        end
        for (pkg,(v1,v2)) in update
            up = v1 <= v2 ? "Up" : "Down"
            info("$(up)grading $pkg: v$v1 => v$v2")
            Write.update(pkg, Read.sha1(pkg,v2))
            push!(updated,(pkg,(v1,v2)))
        end
        for (pkg,ver) in remove
            info("Removing $pkg v$ver")
            Write.remove(pkg)
            push!(removed,(pkg,ver))
        end
    catch
        for (pkg,ver) in reverse!(removed)
            info("Rolling back deleted $pkg to v$ver")
            @recover Write.install(pkg, Read.sha1(pkg,ver))
        end
        for (pkg,(v1,v2)) in reverse!(updated)
            info("Rolling back $pkg from v$v2 to v$v1")
            @recover Write.update(pkg, Read.sha1(pkg,v1))
        end
        for (pkg,ver) in reverse!(installed)
            info("Rolling back install of $pkg")
            @recover Write.remove(pkg)
        end
        rethrow()
    end
end
resolve() = Dir.cd() do
    resolve(Reqs.parse("REQUIRE"))
end

# Metadata sanity check
check_metadata(julia_version::VersionNumber=VERSION) = Dir.cd() do
    avail = Read.available()
    instd = Read.installed(avail)
    fixed = Read.fixed(avail,instd,julia_version)
    deps  = Query.dependencies(avail,fixed)

    problematic = Resolve.sanity_check(deps)
    if !isempty(problematic)
        warning = "Packages with unsatisfiable requirements found:\n"
        for (p, vn, rp) in problematic
            warning *= "    $p v$vn : no valid versions exist for package $rp\n"
        end
        warn(warning)
        return false
    end
    return true
end
check_metadata(julia_version::String) = check_metadata(convert(VersionNumber, julia_version))

end # module
