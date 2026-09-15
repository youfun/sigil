# Agents Demo UI Reference Summary

> Date: 2026-05-14  
> Reference project: `/Users/box/dev-code/demo/cc-like-elixir/upstream_refs/agents_demo`  
> Scope: UI structure, visual system, LiveView/CSS conventions, and reusable patterns for Sigil.

## 1. Overall UI Positioning

Agents Demo uses a clean, IDE-like AI workspace UI:

- Full-screen application shell (`h-screen`, `w-screen`, `overflow-hidden`).
- Calm neutral background with a slightly raised surface layer.
- Conversation-first center panel.
- Operational context in sidebars: tasks, files, thread history.
- Strong state feedback for agent work: loading, thinking, tool calls, tool approval, questions, file results.
- Tailwind utility classes for most structure and interaction states, backed by global CSS tokens.

The design goal is not decorative complexity. It prioritizes:

1. readability,
2. dense but clear agent status display,
3. predictable workspace layout,
4. explicit human-in-the-loop affordances,
5. consistent color semantics for agent/tool states.

## 2. CSS Architecture

Main file:

- `assets/css/app.css`

Important characteristics:

### Tailwind v4 Setup

The reference project keeps the Phoenix/Tailwind v4 import style:

```css
@import "tailwindcss" source(none);
@plugin "@tailwindcss/typography";
@source "../css";
@source "../js";
@source "../../lib/agents_demo_web";
```

It also loads Heroicons and daisyUI plugins, but custom UI is mostly implemented through Tailwind utilities plus CSS variables.

### LiveView Wrapper Fix

The project explicitly makes LiveView wrapper nodes transparent to layout:

```css
[data-phx-session], [data-phx-teleported-src] { display: contents }
```

This is important for full-screen flex layouts. Without it, LiveView-generated wrapper nodes can become unexpected flex children and disturb panel sizing.

### Design Tokens

The project defines app-specific CSS variables on `:root`:

```css
--color-primary: #1c3c3c;
--color-user-message: #076699;
--color-avatar-bg: #ebe8fe;
--color-secondary: #1c3c3c;
--color-success: #10b981;
--color-warning: #f59e0b;
--color-error: #ef4444;
--color-background: #f9f9f9;
--color-subagent-hover: #d0c9fe;
--color-surface: #f9fafb;
--color-border: #e5e7eb;
--color-border-light: #f3f4f6;
--color-text-primary: #111827;
--color-text-secondary: #6b7280;
--color-text-tertiary: #9ca3af;
```

It also defines spacing, typography, font weights, and radius tokens.

Dark mode is handled by a `prefers-color-scheme: dark` media query that swaps the same semantic tokens rather than changing component code.

## 3. Layout Model

Primary chat UI is defined in:

- `lib/agents_demo_web/components/chat_components.ex`
- `lib/agents_demo_web/live/chat_live.ex`

The main shell is:

```heex
<div class="flex flex-col h-screen w-full bg-[var(--color-background)]">
  <header ...>...</header>
  <div class="flex flex-1 relative overflow-hidden">...</div>
  <form ...>...</form>
</div>
```

### Main Regions

1. **Header**
   - Fixed height: `h-[70px]`.
   - Contains app title, icon, debug toggle, thread history, new thread, user/settings/logout controls.
   - Uses border bottom and background token.

2. **Body**
   - `flex flex-1 relative overflow-hidden`.
   - Optional thread history sidebar appears to the left of chat.
   - Chat message panel fills remaining space.

3. **Input Bar**
   - Fixed bottom form.
   - Border top, subtle upward shadow.
   - Large rounded input and square send/stop button.

4. **Tasks/Files Sidebar**
   - Separate left sidebar component.
   - Collapsible from `w-80` to `w-[60px]`.
   - Uses `transition-all duration-300` for smooth width changes.

## 4. Visual Language

### Color Semantics

The UI consistently maps agent/tool states to colors:

| State | Color theme | Usage |
|---|---|---|
| Primary/app action | deep green/teal | app icon, primary buttons, active tabs |
| User message | blue | user bubble, input focus |
| Success/completed | green | completed tools, completed todos, approval |
| Warning/interrupted/question | yellow/amber | HITL approval, interrupted tools |
| Error/cancelled | red | failed/cancelled tools, reject/cancel |
| Informational/tool running | blue | executing tools, streaming tool call |
| Muted/passive | gray | pending todos, secondary text, empty states |

### Typography

- System sans stack: `-apple-system`, BlinkMacSystemFont, Segoe UI, Roboto, etc.
- Headings use semibold weight.
- Body text uses strong line height (`1.5`) for readability.
- Code/arguments use monospaced font and smaller sizes.

### Surfaces

The app distinguishes:

- `--color-background`: page/canvas background.
- `--color-surface`: cards, sidebars, assistant messages.
- `--color-border`: structural borders.
- `--color-border-light`: hover or subtle fill.

This allows a mostly flat UI that still has clear panel separation.

## 5. Component Patterns

### Header Controls

Header buttons are icon-only, transparent by default, and become filled on hover:

```heex
class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded-md hover:text-[var(--color-text-primary)] hover:bg-[var(--color-border)] transition-colors"
```

Pattern:

- muted icon by default,
- stronger text on hover,
- subtle background fill,
- compact square target.

### Chat Messages

Normal text messages use compact rounded blocks:

- User: `bg-[var(--color-user-message)] text-white`
- Assistant: `bg-[var(--color-surface)]`
- Tool: `bg-[var(--color-background)]`

Messages are displayed in a vertical stream with `gap-4`.

### Empty States

Empty states are centered and minimal:

- large muted icon,
- short title,
- one secondary helper line.

Example: “Start a Conversation / Ask me anything to get started”.

### Streaming State

Streaming assistant content shows:

- same surface as saved assistant message,
- small pulsing cursor when text is still streaming,
- tool call previews as blue status rows.

### Thinking Blocks

Thinking output is subdued and collapsible:

- opacity reduced by default,
- hover restores full opacity,
- chevron rotates via `Phoenix.LiveView.JS.toggle_class`,
- content lives in a low-contrast bordered inner card.

This keeps reasoning/debug context available without overwhelming normal reading.

### Tool Call Display

Tool calls have two views:

1. **Normal view**
   - User-friendly text.
   - Left border status card.
   - Icon communicates status.
   - Small badges for failed/cancelled/approved/declined.

2. **Debug view**
   - Technical card with tool name, call id, arguments, errors.
   - Uses tinted backgrounds by state.
   - Details/summary hides verbose JSON until expanded.

Normal tool cards use a consistent pattern:

```heex
"flex items-center gap-2 ml-1 pl-3 pr-4 py-2 border-l-4 rounded"
```

State-specific fills:

- blue for normal/executing,
- yellow for interrupted,
- red for cancelled/failed,
- orange for rejected.

### Human Approval Prompt

The tool approval prompt is visually distinct and anchored above the input area:

- yellow top border/background,
- shield icon,
- bold heading “Human Approval Required”,
- optional sub-agent badge,
- current tool card,
- explicit Reject and Approve buttons.

This makes HITL interruption impossible to miss while preserving the main chat context.

### Question Prompt

The question prompt mirrors approval prompt structure but uses blue:

- blue top border/background,
- question icon,
- optional remaining-count badge,
- option cards with hover border/background transitions,
- form support for single-select, multi-select, and free-text/other.

### Todo UI

The sidebar todo list includes:

- progress summary (`completed / total`, percentage),
- progress bar,
- per-item status dot,
- line-through for completed/cancelled.

Inline todo snapshots in chat use fixed-size status boxes:

- pending: outlined empty square,
- in-progress: outlined warning square with small filled center,
- completed: filled green with check,
- cancelled: filled red with x.

This fixed footprint keeps rows aligned.

### Files UI

Files are grouped by directory:

- folder heading row,
- file rows with document icon,
- basename display with full path in title,
- hover background transition.

File viewer modal:

- black translucent overlay,
- centered surface card,
- max width `max-w-4xl`, max height `90vh`,
- header with file icon/name,
- path strip in monospace,
- rendered/raw toggle,
- scrollable content area,
- footer close button.

## 6. Interaction & Motion

The UI uses understated interactions:

- `transition-colors` for buttons, tabs, rows.
- `transition-all duration-300` for sidebar collapse.
- `animate-spin` for active tool/loading indicators.
- `animate-pulse` for streaming cursor and identified tool calls.
- Hover-only destructive controls in thread history (`opacity-0 group-hover:opacity-100`).

The result is responsive without excessive animation.

## 7. LiveView-Specific Practices

### Streams

Conversation list and messages use LiveView streams:

```heex
<div id="messages-list" phx-update="stream">
  <div :for={{id, message} <- @streams.messages} id={id}>...</div>
</div>
```

The reference keeps stream containers dedicated to stream children, matching LiveView guidance.

### Hooks

Scrollable containers use hooks:

- `ChatContainer` for chat scrolling behavior.
- `ConversationList` for history/infinite loading behavior.
- `QuestionForm` for enabling/disabling form controls around custom question UI.

### HEEx Class Lists

Conditional styling uses HEEx class lists consistently:

```heex
class={[
  "base classes",
  @active_tab == "tasks" && "active classes",
  @active_tab != "tasks" && "inactive classes"
]}
```

This keeps state styling declarative and avoids string concatenation.

## 8. Welcome Page Pattern

`WelcomeLive` uses a centered landing layout:

- full-screen background,
- central max-width container,
- round icon mark,
- large title and subtitle,
- prominent login/register card,
- three feature cards in a responsive grid.

This is a clean onboarding pattern, visually consistent with the chat app through shared tokens.

## 9. Reusable Lessons for Sigil

Recommended takeaways for Sigil UI:

1. **Keep layout wrappers transparent**  
   Always include the LiveView wrapper fix for full-screen flex layouts:
   ```css
   [data-phx-session], [data-phx-teleported-src] { display: contents }
   ```

2. **Use semantic CSS variables**  
   Component code should reference `--color-*` tokens instead of hardcoded colors where possible.

3. **Separate layout from state**  
   Keep panel dimensions and flex behavior stable; state changes should usually affect color, text, and visibility, not the structural layout.

4. **Prefer compact status cards for tools**  
   Agent/tool events read best as small left-border cards rather than full chat bubbles.

5. **Make HITL visually unmistakable**  
   Approval/question prompts should use a dedicated color band above the input area.

6. **Keep debug details collapsible**  
   Normal users see friendly tool names; debug mode reveals raw arguments/results.

7. **Use fixed-size status glyphs**  
   Todos and tool states should reserve consistent visual space to avoid row jitter.

8. **Use streams for long lists**  
   Messages and conversation history should stay stream-backed to avoid LiveView memory and patch-size issues.

9. **Rely on subtle motion only**  
   Transitions, pulse, and spin are enough. Avoid large layout animation unless collapsing panels.

## 10. File Map Reviewed

Reference files reviewed:

- `assets/css/app.css`
- `lib/agents_demo_web/live/chat_live.ex`
- `lib/agents_demo_web/components/chat_components.ex`
- `lib/agents_demo_web/live/welcome_live.ex`
- `lib/agents_demo_web/components/layouts/root.html.heex`

