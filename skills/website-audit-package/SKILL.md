---
name: website-audit-package
description: Assemble a multi-workstream website audit into one client-ready deliverable — a before/after evidence package with a fixed folder shape, three-state finding labels, a one-screen overview, and a hypotheses scorecard. Use when compiling screenshots, UX findings, performance numbers and metadata results into a single package; when producing a "before" record ahead of a redesign, migration, replatform or cutover; when a client asks what we found and what it will change; or when several separate audits need one cover, one index and one consistent register. Also use when a previous audit has gone stale and its findings need re-labelling against work already shipped.
---

# Website Audit Package

Four separate audits produce four separate documents. A client receives one thing.
This skill is the shape that turns the first into the second without losing the
evidence, and without a document that quietly rots the week after it ships.

The failure mode is not a missing finding. It is a package that reads as
authoritative while describing a site that no longer exists.

## The three-state rule

**This is the load-bearing idea. Apply it before anything else.**

Any site worth auditing is usually mid-project, so "is this still true?" has three
answers, not two. Every finding carries one:

| Label | Means |
|---|---|
| **Live** | Still true on the published site today |
| **Fixed in source, awaiting publish** | Solved in the branch; invisible to users until release |
| **Open** | Not yet addressed |

Collapsing these produces two opposite errors in the same document: tickets raised
for problems already solved, and no credit for work already done. On a project
shipping daily, an audit two weeks old can be *more* wrong about progress than
about defects.

Get the state from the tracker and the source, never from the rendered site. A
storefront looking broken is not evidence the fix is missing; it is evidence the
fix has not published.

## Shape

```
<yyyy-mm-dd>-<domain>/
  README.md              front door: what, when, how to read, provenance
  report/                the deliverable — client-facing
    00-executive-summary.md      one page, plain English, no jargon
    01-experience-review.md      what a user runs into
    02-performance.md            load times and where the time goes
    03-architecture-and-ia.md    structure, semantics, structured data, debt
    04-agent-readability.md      what AI assistants can read
    05-analytics.md              the visitor baseline
    99-method-and-gaps.md        method, limits, corrections
  overview/              published pages (see Deliverables)
  evidence/              how to read the captures; raw analytics exports;
                         metadata-audit/<page>/ holds what the register measures
  internal/              analyst notes, case-study drafts — NOT client-facing
  index.html             contact sheet          <- written by the capture tool
  manifest.json          machine-readable index <- written by the capture tool
  register.json          findings register      <- written by scripts/register.py
  register.md            the register, one page <- written by scripts/register.py
  <set>/                 screenshots by set     <- written by the capture tool
  raw/                   per-set capture records<- written by the capture tool
```

The split matters more than the filenames: **the evidence layer is machine-written
and never hand-edited; the report layer sits on top and can be rewritten freely.**

## The register

Between the two layers sits one more machine-written artifact: the findings
register. `scripts/register.py build <package>` runs the measuring tools on the
files saved under `evidence/` and writes `register.json` and a one-page
`register.md` at the package root. Every finding carries the three-state label,
a severity with the decision-tree line it comes from, the measured sentence with
its number, the evidence files the tool actually read, why it matters, and how we
would know we are wrong. **A finding whose evidence pointer does not resolve
cannot be emitted**, and `scripts/register.py check <package>` refuses a register
that has been edited into that state, or whose evidence files have changed since
they were measured (it records their hashes; it does not re-measure, `build`
does). A refused or failed `build` removes the register an earlier build left,
so a stale one never stands beside changed evidence. Every claim that failed the research behind
this (#69) was a claim with a citation that did not support it; the register is
the layer that cannot do that.

Today the one constituent audit with a machine output is audit-metadata, so the
register covers the metadata layer. For each page, save what `inventory.py`
reads under `evidence/metadata-audit/<page>/`: `page.html`, plus `robots.txt`,
`llms.txt`, `headers.txt`, `sitemap.xml`, a one-line `url` file and a one-line
`captured` file holding the capture time in ISO 8601 with a timezone, where you
have them. The directory keeps the name audit-metadata had before 2026-11:
it is part of the package, and packages already delivered use it. The
capture time becomes each finding's `asOf`; without it the register falls back
to the `Date` header saved in `headers.txt`, then to the file's own timestamp,
and `asOfSource` says which. A missing optional input is recorded as checks not
run, never as a pass. Experience, performance and the capture join the register when they emit
something machine-readable; until then its limits section says so. `state` is
`Live` as of the capture time, and re-labelling against the tracker is the
human step the generator cannot take.

`internal/` exists so the wrong register cannot be handed over by accident. Notes
written peer-to-peer, and any prospect-facing case-study draft, live there and stay
out of the client index.

## Sequence

Run the constituent audits first, then compile. Compiling as you go produces a
document that argues for findings instead of reporting them.

1. **Capture** — [site-visual-baseline](../site-visual-baseline/). Full-page, three
   viewports, filenames derived from URL and viewport so a later run aligns
   file-for-file. This is what makes an after-column possible at all.
2. **Experience** — [review-product-ux](../review-product-ux/). Measured in a
   browser from computed styles, not judged from screenshots.
3. **Performance** — [web-perf](../web-perf/). Capture desktop *and* mobile; the
   gap between them is frequently the headline.
4. **Machine readability** — [audit-metadata](../audit-metadata/). Structured data,
   crawler files, `llms.txt`. Save what its `inventory.py` reads under
   `evidence/metadata-audit/<page>/`, so the register can measure from it.
5. **Analytics** — the client's own export. Usually arrives last; see Slots.
6. **Compile** into the shape above.

Steps 1–4 are independent and can run in any order or in parallel. Step 6 cannot
start until at least the capture exists, because every report claim must point at
a file.

## The rules that make it reusable

1. **Never hand-edit the evidence layer.** If a capture is wrong, re-run the
   capture. Editing it destroys the one property that makes it evidence.
2. **Every number traces** to a file in the evidence layer or a named, dated
   source. No estimates. No silent rounding.
3. **Three-state labels on every finding.** Always.
4. **Measure before you opine.** Go looking for problems and you find opinions;
   measure first and the problems introduce themselves.
5. **Find a control group.** The most valuable thing in an audit is usually an
   untouched surface — a stock template, an unedited section, a page nobody has
   been near. It converts "this site is badly built" into "these edits broke it",
   which is a completely different and far more actionable project.
6. **State what you did not measure**, in the deliverable, not in a footnote.
7. **Record your own corrections.** They calibrate how much of the rest to trust,
   and an audit that never corrected itself has not been checked.
8. **Separate client-facing from internal** at the folder level.

## Deliverables beyond the documents

Two published pages usually earn their place. Load the `artifact-design` skill
before building either.

**The overview.** One screen, plain English, client-facing. If a viewport
constraint is agreed, it is binding and it is the first thing to break — so
measure it rather than trusting it:

```js
const s = document.querySelector('.sheet');
document.body.style.width = '1440px'; s.style.minHeight = '0';
s.getBoundingClientRect().height;   // must stay under the budget
```

Four numbers well-presented beat twelve crammed. Anything needing more room is a
special-analysis section, not a smaller font.

**The hypotheses page.** What the work is predicted to do, written *before* the
change ships. Each prediction names the metric it will be judged on, carries an
explicit empty baseline slot, and states **how we would know we are wrong**. That
last line is what makes it a prediction rather than a pitch. Add a confounders
section — a single release is not an experiment, there is no control group, and
saying so first is what makes the rest credible.

## Slots

Analytics almost always arrives after everything else. Do not wait, and do not
guess — ship the section as an explicit slot naming exactly which reports to
export and where they land. A visitor number nobody has seen undermines every
measured number in the package.

Two exports are worth naming specifically because they are rarely in a default
report and often carry the commercial finding: the recurring-versus-one-time
split, and the share of orders through accelerated checkout. The second is the
measurable fingerprint of a broken primary buy path.

## Traps

**Measuring the wrong target.** Auditing the published site while the team works
on an unpublished branch produces findings that are real and already fixed. State
which target was measured, at the top, every time.

**Transfer-size overstatement.** Image CDNs negotiate modern formats from request
headers. Measure without browser `Accept` headers and a page can report several
times its real weight. Any speed number quoted to a client must account for this.

**Lab numbers read as field numbers.** Simulated performance runs are reliable
about the *shape* of a problem — which pages, which phase, desktop versus mobile —
and not about absolute seconds. Say so at the point of use, not once in an
appendix.

**Retracted findings.** When a finding turns out to be wrong, keep it in the
document, marked retracted, with what was actually true. Deleting it hides that
the audit corrects itself — and a recommendation to remove a working feature is
exactly the kind of error a reader needs to see was caught.

**Client material in git.** Screenshots and reports for a client are usually
gitignored, correctly. That also means they have no history and no remote: they
need a backup that is not the repository, and saying "it's in the repo folder" is
not one.
