# 02 — History: why Flatcar exists and what each transition changed for users

If you are evaluating Flatcar for a regulated estate, the history is not trivia. Flatcar has changed stewards twice, and
you are being asked to depend on its governance, its release infrastructure and its funding model for years. This
document walks the transitions in order and, for each one, says what changed for the people running nodes. Dates and
quotes come from the project's own posts and repositories, linked at the bottom. Where the sources I could read do not
state something, I say so rather than fill the gap.

## CoreOS Container Linux: the idea Flatcar preserves

CoreOS Container Linux introduced the combination this repository is about: a minimal image with a read-only `/usr`, an
A/B partition scheme borrowed from ChromeOS so that updates are atomic and reversible, automatic updates delivered
through release channels, and a first-boot provisioning tool (Ignition) in place of long-lived configuration
management. Flatcar's founders describe preserving exactly that: "We believe the approach that CoreOS pioneered with
CoreOS Container Linux is correct and aim to preserve that" ([FAQ][faq]). The disk layout still shows the lineage:
the partition table is documented as inspired by Chromium OS ([disk layout][disk-layout]), and for machines updated from
CoreOS, the first-boot flag file is still checked under its old `coreos/` name ([boot process][boot-process]).

## The fork: Kinvolk announces Flatcar (March 2018)

On 6 March 2018 Kinvolk announced Flatcar Linux as "a friendly fork of CoreOS' Container Linux", compatible with it and
"independently built, distributed and supported" by Kinvolk ([announcement][announce]). The reasoning matters because it
explains Flatcar's architecture. Kinvolk had been asked to support Container Linux commercially, and concluded that
"providing commercial support for a Linux distribution is more difficult and can not be done without having full control
over the means of building, signing and delivering the operating system images and updates." That is why Flatcar owns its
own build system, its own signing keys and its own update service rather than relying on a vendor's.

The announcement also gives the second reason, which was a reaction to Red Hat's acquisition of CoreOS: a project at the
core of your systems should have more than one commercial steward. The post puts it as a bus-factor argument, saying
Container Linux "has a bus factor of 1" and that Flatcar "brings that to 2".

What it changed for users: a drop-in alternative existed. Migration from CoreOS Container Linux was described later as
"potentially amount to a simple one-line change" ([2020 post][eol-post]). The Red Hat acquisition itself was announced
before this post (it is referenced as already public); the press release is linked from the 2020 post.

> ⚠️ Verify: the exact date of Red Hat's acquisition announcement is not stated in the project sources I read. Check
> Red Hat's press release (linked in Sources) if you need the date for a vendor-risk file.

## End of life of CoreOS Container Linux (announced February 2020, effective 26 May 2020)

In February 2020 Red Hat announced the end of life of CoreOS Container Linux for 26 May 2020, with a harder second date:
after 1 September 2020, per the project's summary of that announcement, "published resources related to CoreOS Container
Linux will be deleted or made read-only. OS downloads will be removed, CoreUpdate servers will be shut down, and OS images
will be removed from AWS, Azure, and Google Compute Engine" ([EOL post][eol-post]).

What it changed for users: the choice stopped being optional. Anyone still on Container Linux had to move, and Flatcar
became, in the project's words, "the only way for current users of CoreOS Container Linux to go forward with active
maintenance and security updates". For Flatcar itself it meant independent development with no upstream to track. The
project's account of the preceding period is blunt: that "in terms of new features, the project has stagnated since the
acquisition was announced." The 27 May 2020 follow-up post announces the restart of innovation (a newer kernel, systemd
and Docker moving through Alpha, Beta and Stable) and lists deprecations Flatcar would drive, such as the `kubelet-wrapper`
and `rkt` ([back on track][back-on-track]).

The same period added features that CoreOS had never provided in open form. The update server, Nebraska, was released as
open source in late 2019 (the 2020 post calls it "one of the few parts of the system that CoreOS had never made
available under an OSS license"), which is what makes running a private update server for an air-gapped estate possible
today. ARM support was reintroduced.

## Kinvolk joins Microsoft (April 2021)

The Flatcar FAQ addresses the next transition directly: "How will Kinvolk's acquisition by Microsoft impact the Flatcar
project?" It answers that Microsoft and Kinvolk were "fully committed to the Flatcar Container Linux user community" and
intended to "expand the universe of partners, contributors, and users", aiming at "a truly open, community-driven
project" ([FAQ][faq]). The link in that answer points to a Kinvolk blog post dated April 2021.

What it changed for users: the main steward of the build and release machinery became part of a hyperscaler, which is
relevant to vendor-risk reviews in both directions: a large company's backing is a continuity argument, and a
single dominant steward is a neutrality question. (Azure support itself predates the acquisition; the project's Azure
post is dated April 2020.) The formal mechanisms you can inspect today are the governance document and CNCF
participation, covered below.

> ⚠️ Verify: I could not retrieve the 2021 Kinvolk post itself (the host is not reachable from my environment). Read it
> before quoting the terms of the acquisition.

## Community LTS, then CNCF

In May 2022 the project moved capabilities that had been exclusive to paid "Pro" images into the free community
images: a Long-Term Support channel, FIPS mode support, Azure GPU drivers and out-of-the-box EKS worker support
([LTS post][lts-post]). The LTS definition from that post is the one still in force: a new LTS major roughly yearly,
18 months of maintenance, 6 months of overlap, and LTS releases branch from a stable release that has passed extra soak
time. The current release documentation repeats those numbers ([switching channels][channels], [RELEASES][releases]).

Flatcar is now a Cloud Native Computing Foundation project. What I can verify from the repositories is the consequence:
the project follows the CNCF Code of Conduct, designates CNCF resources and a CNCF Code of Conduct Committee for conflict
escalation, requires maintainers to appear in the CNCF project maintainers list, keeps its community channels on the
CNCF and Kubernetes Slack workspaces, and the release guide references a CNCF-hosted CDN host for channel metadata
([governance][governance], [maintainers][maintainers], [release guide][release-guide]).

> ⚠️ Verify: I could not read the CNCF project page, so I am not stating the maturity level or acceptance date here. The
> project README links a conference talk about "CNCF acceptance"; check <https://www.cncf.io/projects/> for the current
> level before putting it in an assessment.

## Governance today

The governance document describes a "flat hierarchy": a Maintainer Council made up of all maintainers is the governing
body, with a published value set that includes "Community over Product or Company", and "each contributor participates
in the project as an individual." Maintainers are nominated by existing maintainers and approved by consensus through a
pull request that edits `MAINTAINERS.md`; a maintainer can be removed by a two-thirds vote of the others. A Security
Response Team is appointed from the council to handle undisclosed vulnerabilities, with access controlled through GitHub
team membership. Maintainers are expected to attend a monthly developer sync ([governance][governance]).

For a risk reviewer, two things follow. First, release and signing authority sits with a defined set of named
maintainers rather than a single company's employees by contract. Second, the maintainers file lists names and GitHub
handles but not employers, so you cannot read vendor concentration from the repository. If vendor diversity matters to
your risk model, that is a question to ask the project directly, and the project keeps a public adopters list
([ADOPTERS][adopters]).

> ⚠️ Verify: the supply-chain document and the release guide still describe infrastructure by reference to Kinvolk-era
> hosts (a build machine in an Equinix Metal data centre, a Jenkins instance under a `kinvolk.io` domain) alongside a
> CNCF-hosted CDN host. They may be partly stale. Ask where signing keys, build machines and the public update server
> are hosted and operated today before documenting it as fact.

## The ecosystem around it

Fedora CoreOS is the other descendant of the CoreOS idea and is covered in doc 08's comparison. Bottlerocket and Talos
are independent designs for the same "OS as a substrate for containers" problem.

> ⚠️ Verify: I did not read Fedora CoreOS's own account of how it relates to Container Linux. Doc 08 compares them by
> mechanism using their documentation and does not rely on a history claim.

## What each transition means for your evaluation

CoreOS to Flatcar gave you continuity of the technical model and a steward with a full build and signing pipeline.
Red Hat's end of life made that steward the only maintained path for the design. Microsoft's acquisition of Kinvolk put
the pipeline inside a large company with an interest in the project. The move to CNCF governance is the project's
mitigation for that concentration, and it is the part you should test with questions: who holds the signing keys, who can
publish to the update server, and what happens to channel metadata and release hosting if one steward withdraws.

## Key takeaways

- Flatcar was forked in March 2018 because commercial support for an OS needs control of build, signing and delivery, not because of a technical disagreement with CoreOS.
- Red Hat's end of life of CoreOS Container Linux (26 May 2020) made Flatcar the maintained path for this design and ended upstream tracking.
- The open-sourced update server (Nebraska) and community LTS are what make private update infrastructure and slow-moving streams practical today.
- Governance is a flat maintainer council under CNCF conventions; verify maturity level, key custody and infrastructure ownership yourself.
- Several dates and the Microsoft/CNCF details need primary-source confirmation (marked above) before they go into a vendor-risk file.

## Sources

- Announcing the Flatcar Linux project (6 March 2018): [`content/blog/2018-03-06-announcing-the-flatcar-linux-project.md`][announce]
- Flatcar Container Linux enters new era after CoreOS End-of-Life announcement (24 February 2020): [`content/blog/2020-02-24-…`][eol-post]
- Container Linux: Back on Track with Flatcar (27 May 2020): [`content/blog/2020-05-27-container-linux-back-on-track.md`][back-on-track]
- Community LTS and advanced features (10 May 2022): [`content/blog/2022-05-10-community-lts-pro.md`][lts-post]
- FAQ (Microsoft/Kinvolk answer, goals): [`content/faq.md`][faq]
- Governance, maintainers, adopters, releases: [`flatcar/Flatcar` governance][governance], [MAINTAINERS][maintainers], [ADOPTERS][adopters], [RELEASES][releases]
- Disk layout and boot process: [`sdk-disk-partitions.md`][disk-layout], [`boot-process.md`][boot-process]
- Release guide (CDN host, LTS process): [`devguide/release-guide.md`][release-guide]
- Red Hat's acquisition press release (linked from the 2020 post): <https://www.redhat.com/en/about/press-releases/red-hat-acquire-coreos-expanding-its-kubernetes-and-containers-leadership>
- CNCF project list (not read; check maturity level): <https://www.cncf.io/projects/>

[announce]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/blog/2018-03-06-announcing-the-flatcar-linux-project.md
[eol-post]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/blog/2020-02-24-flatcar-container-linux-enters-new-era-after-coreOS-end-of-life-announcement.md
[back-on-track]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/blog/2020-05-27-container-linux-back-on-track.md
[lts-post]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/blog/2022-05-10-community-lts-pro.md
[faq]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/faq.md
[governance]: https://github.com/flatcar/Flatcar/blob/42d9daa78c15f0c2d8f370bb7516de95cfb23819/governance.md
[maintainers]: https://github.com/flatcar/Flatcar/blob/42d9daa78c15f0c2d8f370bb7516de95cfb23819/MAINTAINERS.md
[adopters]: https://github.com/flatcar/Flatcar/blob/42d9daa78c15f0c2d8f370bb7516de95cfb23819/ADOPTERS.md
[releases]: https://github.com/flatcar/Flatcar/blob/42d9daa78c15f0c2d8f370bb7516de95cfb23819/RELEASES.md
[disk-layout]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/devguide/sdk-disk-partitions.md
[boot-process]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/fb-provision/ignition/boot-process.md
[release-guide]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/devguide/release-guide.md
[channels]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/releases/switching-channels.md
