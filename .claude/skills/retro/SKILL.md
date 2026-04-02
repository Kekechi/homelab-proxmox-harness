---
name: retro
description: Retrospective on a completed session. Surfaces prompting lessons and workflow insights, then recommends the right action — from no action to updating an existing skill or creating a new one.
disable-model-invocation: false
---

# Skill: Session Retrospective

Reflect on a session that just ended. The primary output is always a **prompting lesson** — something the user can carry into future sessions. Skill creation or updates are downstream actions, not the goal.

## When to Activate

- A session just ended and the user wants to reflect on it
- The user asks "what did we do well?", "how could that have gone better?", or "should this be a skill?"
- The user wants to improve how they prompt or structure future sessions

## Phase 1: Orient

Read the session. Identify:
- **Session type** — design exploration, planning, debugging, assessment, ad-hoc discussion, etc.
- **What was accomplished** — one sentence, concrete
- **Shape of the session** — did it flow, did it stall, did corrections happen, was the goal reached?

State this back to the user briefly before asking anything. It confirms you read the session correctly and gives them a chance to reframe before the retro begins.

## Phase 2: Evaluate on six questions

Work through these in order. Each should produce a specific, concrete answer — not generalities.

**1. What worked?**
Name specific moments: a question that unblocked the design, a correction the user made that improved the output, a framing that made a decision easier. Avoid "the discussion was productive" — say what specifically was productive and why.

**2. What created friction?**
Where did the session stall, require correction, or produce an output the user had to push back on? What caused it — an assumption, a vague prompt, a wrong mode (planning when brainstorming was needed)?

**3. What prompting pattern worked?**
Extract the signal from the user's prompts that shaped the session well. Quote or paraphrase if useful. This is the most portable lesson — it travels to future sessions regardless of topic.

**4. What prompting would have helped?**
If the session had friction, what could the user have said upfront to prevent it? Be specific: "saying X at the start would have prevented Y."

**5. Is this session type repeatable?**
Was the shape of this session specific to this topic, or would the same structure apply to other topics? This is the gate for whether formalization makes sense.

**6. What's the right action?**
Choose one:

| Action | When |
|---|---|
| **No action** | Session was one-off or too context-specific to generalize |
| **Save to memory** | A prompting insight or workflow preference worth carrying forward |
| **Update existing skill** | The session revealed a gap or improvement in an existing skill |
| **Create new skill** | Genuinely new repeatable pattern not covered by any existing skill |

## Phase 3: Output

**Always produced:**
A prompting lesson — one or two sentences the user can use next time. Even if the session went perfectly, name why it worked so it can be replicated.

**If saving to memory:**
Write a feedback memory entry. Focus on the prompting behavior or workflow preference, not the session content.

**If updating an existing skill:**
Identify the specific skill and propose the exact change — a new section, a revised phase, an added rule. Don't rewrite the whole skill. Present the diff and confirm before writing.

**If creating a new skill:**
Draft the skill collaboratively — propose the structure, confirm with the user, then write it. Follow the existing skill file format (frontmatter + phases + output + checklist).

**If no action:**
State why the session doesn't generalize. The prompting lesson is still the deliverable.

## Tone

- Lead with what was specific and concrete, not general praise or critique
- "The session went well" is not a useful output — "asking one question at a time prevented the user from getting overwhelmed by options" is
- If the recommendation is "no action," say so directly — that's a valid and useful outcome
- Don't push toward skill creation when memory or no action is the right call

## Checklist before concluding

- [ ] Session type and outcome stated accurately
- [ ] At least one specific moment called out in "what worked"
- [ ] Friction identified with a cause, not just a symptom
- [ ] Prompting lesson is portable — applies beyond this session's topic
- [ ] Action recommendation is one of the four options, not hedged
- [ ] If creating/updating a skill: confirmed with user before writing
