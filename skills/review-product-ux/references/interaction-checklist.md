# Interaction checklist

Use this checklist selectively. Follow relevant paths rather than mechanically reporting every item.

## Escape and recovery

- Every overlay has a visible, reachable dismissal method.
- Escape behavior is appropriate and reliable.
- Cancel and close semantics are distinct from save or submit.
- Browser Back does not unexpectedly discard work or leave an inconsistent state.
- Focus returns after an overlay closes.
- Scroll locking is restored.
- Destructive actions provide proportional confirmation or undo.
- Multi-step flows allow safe abandonment and recovery.
- Errors preserve valid input and provide a next action.

## Feedback and system status

- Every user action produces timely, perceivable feedback.
- Async actions indicate progress and prevent duplicate activation.
- Success messages identify what changed.
- Failures identify what did not happen and how to recover.
- Long operations communicate whether the user may leave safely.
- Toasts remain long enough to read and do not contain the only recovery path.

## Forms

- Persistent labels exist.
- Instructions precede the action they govern.
- Required state is clear before submission.
- Errors appear near fields and in a useful summary when needed.
- Focus moves appropriately after failed submission.
- Formatting requirements are visible before error.
- Paste, autofill, and password managers work.
- Input types and mobile keyboards match expected data.
- Values survive recoverable failures and navigation where appropriate.

## Navigation and orientation

- Current location is clear.
- Page titles and headings match navigation labels.
- Back and close actions have predictable destinations.
- Logo, home, breadcrumbs, and global navigation behave consistently.
- Deep links load usable states.
- Empty search and no-result states offer recovery.

## Controls

- Controls communicate affordance and state.
- Icon-only controls have accessible names and understandable icons.
- Disabled controls are used sparingly and explain unavailable actions when necessary.
- Toggle, checkbox, radio, tabs, and disclosure patterns match their semantics.
- Hit areas include the visible label where expected.
- Repeated actions remain in consistent positions.

## Overlays and layered UI

- Dialogs have titles and clear primary purpose.
- Focus enters, remains appropriately contained, and returns on close.
- Nested overlays do not create traps or conflicting Escape behavior.
- Menus remain open while users move toward valid targets.
- Popovers and tooltips remain within the viewport.
- Mobile sheets and dialogs expose close actions above the fold.
- Background content is not accidentally operable while modal UI is active.

## Responsive and touch

- Controls are reachable with one hand when task-critical.
- Touch targets are not crowded.
- Sticky headers, cookie banners, chat widgets, and bottom bars do not cover actions.
- Orientation changes do not lose state.
- Mobile menus can open, scroll, navigate, and close.
- Dialog content scrolls without hiding the header or actions.
- Text does not truncate essential meaning.

## Content and decision clarity

- Primary action is unambiguous.
- Button labels describe consequences.
- Destructive actions are visually and verbally distinct.
- Confirmation copy names the affected object and consequence.
- Empty states explain why the area is empty and what can be done.
- Help text appears where uncertainty occurs, not far away.
- Technical errors are translated into user-relevant language.

## Accessibility behavior

- Keyboard focus is visible.
- Focus order matches reading and task order.
- Interactive elements use appropriate semantics.
- Status and error changes are announced where needed.
- Color is not the only signal.
- Contrast supports readability and state recognition.
- Hover content is dismissible, hoverable, and persistent enough to use.
- Reduced motion does not remove necessary context.
