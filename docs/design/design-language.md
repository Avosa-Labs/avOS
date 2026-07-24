# Design language

The interface principles the platform is designed against. They are normative:
a surface that violates one is wrong, not merely unfashionable. The through-line
is that the interface should make the system's intelligence and authority
legible, never decorative.

## Principles

1. **Calm authority.** The interface is quiet by default and speaks when it has
   something the person must decide. It does not compete for attention; it earns
   it at the moments that matter — an approval, a denial, a completion.
2. **Visible intelligence.** Agent activity is always visible. What an agent is
   doing, on whose authority, and how far along, is on screen — never a hidden
   process the person discovers only by its effects.
3. **Direct manipulation.** The person acts on the thing, not on a description of
   it. State changes because the person changed it, and the change is shown.
4. **Semantic depth.** Surfaces project the control plane's real state rather
   than holding their own copy, so what is shown is what the system can account
   for. A surface never presents an action as complete before it is.
5. **Motion that explains state.** Animation conveys what changed and why, not
   ornament. A transition that does not explain a state change does not belong.
6. **One coherent geometry.** A single spatial and typographic system across
   every surface and form factor, so the platform is recognizable without a logo.
7. **Controlled personalization.** The person can adapt the surface within bounds
   that preserve legibility and the security-critical affordances; personalization
   never hides an approval or disguises a denial.
8. **Strict performance budgets.** Interaction stays within the budgets the
   platform enforces; a surface that cannot meet them is redesigned, not shipped
   slow.
9. **No pasted-on chatbot layer.** Conversation is a first-class interaction where
   it fits, integrated into the surface — not a chat window bolted over an
   otherwise unchanged UI.
10. **Adaptation across form factors.** One design that adapts across phone,
    tablet, glasses, desktop, vehicle, room, robot, and screenless session, each
    reducing or extending the baseline deliberately (`shell/*/adaptation`).

## Review bar

A design fails review when it is merely "a familiar OS with different colors."
Review asks: what original platform idea is present, what problem is solved
better, whether the surface is recognizable without a logo, whether agent
activity is clearer, whether it works without agents at all, and whether it
survives another form factor. A design that cannot answer these is not ready.
