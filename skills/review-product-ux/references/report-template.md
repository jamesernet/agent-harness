# UX review: [product or flow]

## Review mode

- **Mode:** Full audit | Implementation review | Visual review
- **Evidence available:** Browser automation, source code, screenshots, design system, other
- **Evidence unavailable:** State missing access or tooling
- **Confidence boundary:** State what this mode can and cannot establish

## Executive assessment

Summarize overall usability, the most consequential pattern, and the recommended first action. Avoid averaging severe defects into a vague score. For limited modes, avoid definitive runtime conclusions.

## Coverage and limitations

- Routes and journeys tested or inspected.
- User roles and states tested or represented.
- Viewports tested or supplied.
- Input modes tested.
- Browser or automation environment.
- Source areas inspected.
- Screenshots reviewed.
- Blocked or untested areas.

## Critical and high-severity findings

### [Finding title]

- **Severity:** Critical | High
- **Evidence:** Browser-observed | Browser-observed and source-confirmed | Partially observed | Screenshot-observed | Code-inferred | Potential
- **Location:** Route, component, viewport, state, or screenshot
- **Behavior or visible issue:** Precise description
- **User impact:** Task, user group, and consequence
- **Reproduction or inspection basis:** Numbered browser steps, source reasoning, or screenshot context
- **Source location:** File, component, and line when available
- **Root cause:** Implementation or design-system cause when supported
- **Recommended fix:** Specific behavioral or implementation correction
- **Verification:** Exact browser steps and states required to confirm the fix
- **Confidence:** High | Medium | Low

Repeat only for genuine critical and high findings.

## High-value quick wins

List small, low-risk corrections with clear user value. Include evidence, location, impact, exact change, and verification.

## Additional findings

Group relevant findings under:

- Interaction and flow
- Forms and feedback
- Keyboard and accessibility
- Responsive behavior
- Visual hierarchy and consistency

Use the same finding fields, in a more compact form when appropriate.

## Systemic source-code findings

Include only when source is available. Identify shared components, patterns, or design-system primitives responsible for repeated defects. Distinguish source-confirmed causes from hypotheses.

## What is already working

Identify effective patterns worth preserving. Be specific and respect the evidence limits of the selected review mode.

## Recommended implementation order

Sequence changes by dependency and consequence:

1. Critical blockers and data-loss risks.
2. High-severity flow and accessibility defects.
3. Repeated systemic component fixes.
4. High-value quick wins.
5. Lower-impact visual refinement.

## Verification plan

Define the browser steps, states, viewports, and input modes required to confirm each major fix and detect regressions. For source-only or screenshot-only reviews, make this the path to runtime confirmation.
