/*******************************************************************************

    Struct to extract & hold library information

    Copyright:
        Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module autopr.LibInfo;

/// Struct to extract & hold library information
struct LibInfo
{
    import autopr.github;
    import internal.json;
    import internal.github.MetaInfo;

    import semver.Version;

    import provider.core;
    import vibe.data.json;

    import std.datetime;

    enum D2Only { No, Yes }

    /// One release of a library
    struct Release
    {
        import std.typecons;

        /// Version of this release
        Version ver;
        /// SHA commit of this release
        string sha;
        /// owner of the associated repository
        string owner;
        /// Time this release was published
        Date published;
        /// Time the support ends
        Nullable!Date support_end;
        /// Whether this release is currently still supported
        bool supported;

        /// Comparison function only comparing the version
        int opCmp ( const Release rel ) { return ver.opCmp(rel.ver); }
    }

    /// map of releases per library
    /// value [lib][orga]
    public Release[][string][string] libs;

    /// fetcher instance to fetch more pages of releases
    private FetchMore fetcher;


    /***************************************************************************

        Returns the list of releases for the given library name, that include
        the given SHA in the list.

        This makes sure you get the right organisation of a given library

        Params:
            name = name of the library
            sha  = sha of the commit matching a version

        Returns:
            list of releases

    ***************************************************************************/

    public Release[] getReleasesForSha ( string name, string sha )
    {
        import std.algorithm : canFind;

        foreach (orga; this.libs)
        {
            auto lib = name in orga;

            if (lib is null)
                continue;

            if ((*lib).canFind!(a=>a.sha == sha))
                return *lib;
        }

        return null;
    }

    /***************************************************************************

        Extracts library & release information

        Params:
            con = connection object (required for refetching)
            json = json to extract the information from
            orgas = organisations to check
            meta_info = meta info object, provides neptune related info

    ***************************************************************************/

    public void extractInfo ( ref HTTPConnection con, Json json, string[] orgas,
        MetaInfo meta_info )
    {
        // Keep fetching info while it's incomplete
        do foreach (orga; orgas)
            this.tryExtractInfo(json, orga, meta_info);
        while (this.fetcher.fetch(con, json, orgas));
    }

    /***************************************************************************

        Tries to extract library release info. If not enough release information
        is present, adds a 'fetch-more-releases' request for the given repo

        Params:
            json = json object to extract data from
            orga = organisation to fetch data for
            meta_info = meta info object to access neptune information

    ***************************************************************************/

    private void tryExtractInfo ( Json json, string orga, MetaInfo meta_info )
    {
        import std.stdio;
        import std.string : translate;
        import std.format;

        auto orga_alias = translate(orga, ['-' : '_']);

        auto edges = json["data"][orga_alias]
            .path!"repositories.edges";

        writefln("\n%s REPOS: %s\n=================\n", orga, edges.length);

        foreach (edge; edges)
        {
            auto lib_name = edge["node"]["name"].get!string;

            auto owner_name = format("%s/%s", orga, lib_name);

            auto meta = owner_name in meta_info.meta_info;

            if (meta is null)
            {
                writefln("Skipping %s which has no meta info", owner_name);
                continue;
            }

            // Assumed default values for supported guarantees
            int maintained_minor_versions = 2;
            int maintained_major_months = 6;

            try
            {
                if (meta.neptune_yaml.isNull())
                    continue;

                import autopr.yaml;

                auto rslt = getSupportGuarantees(meta.neptune_yaml);

                // Skip non-library projects
                if (!rslt.library)
                    continue;

                maintained_minor_versions = rslt.minor_versions;
                maintained_major_months = rslt.major_months;
            }
            catch (Exception exc)
            {
                writefln("Skipping %s. Failed to parse yaml: %s", lib_name, exc);
                continue;
            }

            bool more_data =
                edge.path!"node.releases.pageInfo.hasPreviousPage".get!bool;

            auto rel_edges = edge.path!"node.releases.edges";

            import std.algorithm;

            foreach (rel_edge; rel_edges) try
            {
                auto tag = rel_edge["node"]["tag"];

                auto rel = Release(
                    Version.parse(tag["name"].get!string),
                    tag.path!"target.target.oid".get!string,
                    orga,
                    DateTime
                        .fromISOExtString(rel_edge
                            .path!"node.publishedAt".get!string[0..$-1])
                        .date);

                // Skip releases we already added
                auto orga_libs = orga in libs;
                if (orga_libs !is null)
                {
                    auto rels = lib_name in *orga_libs;

                    if (rels !is null)
                        if ((*rels).canFind(rel))
                            continue;
                }

                this.libs[orga][lib_name] ~= rel;
            }
            catch (Exception exc)
            {
                //writefln("Exception: %s", exc);
                writefln("Skipping unparsable version %s",
                    rel_edge);
            }

            if ((orga in this.libs) is null)
                continue;

            auto lib = lib_name in this.libs[orga];

            if (lib is null)
            {
                writefln("No releases found in %s", lib_name);
                continue;
            }

            bool need_more = this.markSupported(more_data,
                maintained_minor_versions, maintained_major_months, *lib, D2Only.No);
            need_more = need_more || this.markSupported(more_data,
                maintained_minor_versions, maintained_major_months, *lib, D2Only.Yes);

            bool has_more =
                edge.path!"node.releases.pageInfo.hasPreviousPage".get!bool;

            if (need_more && has_more)
            {
                writefln("Requesting prev page: %s (%s)",
                         edge.path!"node.releases.pageInfo",
                         edge.path!"node.releases.edges".length);
                this.fetcher.addReleaseRequest(lib_name,
                    edge.path!"node.releases.pageInfo.startCursor".get!string,
                    orga);

                continue;
            }

            writefln("LIB: %s Releases: %s", lib_name,
                     (*lib).filter!(a=>a.supported).map!(a=>a.ver));
        }
    }


    /***************************************************************************

        Finds out which releases are supported and marks them as such

        Params:
            complete = should be true if the list of releases is known to be
                       complete (no further pages to process)
            maintained_minor_versions = amount of maintainted minor versions
            maintained_major_months = amount of months a major version is
                                      supported after no longer being the latest
                                      major version
            releases = list of releases
            d2only   = if yes, only consider d2 updates,
                       if no, only consider non-d2

        Returns:
            true if more data is required, else false

    ***************************************************************************/

    bool markSupported ( bool complete, int maintained_minor_versions,
        int maintained_major_months, Release[] releases, D2Only d2_only )
    {
        import std.range;
        import std.algorithm;
        import std.datetime;

        auto d2filter ( Release rel )
        {
            return d2_only == rel.ver.metadata.canFind("d2");
        }

        // Relevant releases are d2 and rc releases, other metadata/prereleases
        // are ignored as we don't know how to handle it
        auto filterRelevant ( Release rel )
        {
            with (rel.ver)
                return (prerelease.startsWith("rc") ||
                    prerelease.empty) &&
                    (metadata.empty || d2filter(rel));
        }

        // Skip early if no releases to mark for us exist
        if (!releases.canFind!filterRelevant)
            return false;

        // Find oldest release. If it is newer than maintained_major_months we
        // don't need to look at older versions. Otherwise we need to fetch all
        // data

        // Sort according to publish time
        auto rel_sorted = sort!((a,b)=>a.published < b.published)(releases);

        auto majors = releases
            .filter!(a=>a.ver.minor == 0 &&
                a.ver.patch == 0 &&
                filterRelevant(a));

        auto oldest_support_end = releases.front.published;
        oldest_support_end.add!"months"(maintained_major_months);
        import std.stdio;

        /* If the oldest rel. we have is outside the major term, then we can
         * assume that there is no older supported release and we can skip any
         * further major release detection */

        // debug output, left in for easy debugging when required
        //writefln("%s >= %s = %s", oldest_support_end , cast(Date)Clock.currTime,
        //         oldest_support_end >= cast(Date)Clock.currTime);

        auto oldest_supported = oldest_support_end >= cast(Date)Clock.currTime;

        import std.typecons;

        // We found no major version. The oldest version we have would be within
        // major support term. We need to check older data.
        if (majors.empty && !complete && oldest_supported)
            return true; // request more data

        // Add the oldest rel. we have and treat it as major, in case the
        // versions don't actually start with a major release
        auto majors_and_oldest = chain(releases.filter!d2filter.takeOne, majors);

        // Find out end support date for each major version
        foreach (ref maj; majors_and_oldest)
        {
            // Find next higher major
            auto next = majors_and_oldest
                .find!(a=>a != maj && a.ver.major == maj.ver.major+1);

            if (next.empty)
                continue;

            with (next.front)
            {
                maj.support_end = published;
                maj.support_end.add!"months"(maintained_major_months);
                maj.supported = maj.support_end >= cast(Date) Clock.currTime();
            }
        }

        // Sort according to version
        sort(releases);

        // Make sure the latest release is _always_ supported
        auto latest = releases.retro.filter!filterRelevant;

        latest.front.supported = true;

        /* Goes through all supported majors and the latest release. For each it
         * finds the maintained minor releases. For each of the minor releases
         * it finds the latest patch release and marks that as supported and
         * sets its support_end time. */
        foreach (ref major;
            chain(majors_and_oldest, latest.takeOne)
                .filter!(a=>a.supported)
                .filter!d2filter)
        {
            // the major itself isn't actually supported (except when it is, see
            // comment below)
            major.supported = false;

            // Only the specific minor/patch releases based on it are supported
            // (except when there are no minor/patch rels. of course)
            auto minors = releases
                .retro
                .filter!(a=>
                    a.ver.major == major.ver.major &&
                    a.ver.patch == 0)
                .filter!filterRelevant
                .take(maintained_minor_versions);

            foreach (minor; minors)
            {
                auto supported_rels = releases
                    .retro
                    .filter!(b=>
                        minor.ver.major == b.ver.major &&
                        minor.ver.minor == b.ver.minor)
                    .filter!filterRelevant
                    .takeOne();

                foreach (ref supported; supported_rels)
                {
                    supported.supported = true;
                    supported.support_end = major.support_end;
                }
            }
        }

        return false;
    }
}
