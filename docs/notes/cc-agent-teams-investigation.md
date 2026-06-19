# Claude Code Agent Teams & Resumability Investigation

**Date:** 2026-06-19  
**Investigation scope:** SendMessage, resumable subagents, Agent Teams, Dynamic Workflows

---

## 1. Agent Teams

**Status:** Experimental, **disabled by default** (flag: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`)  
**When shipped:** Introduced as experimental feature in Claude Code; not yet GA  
**Mechanic:** Multi-subagent orchestration with shared task queue

### How It Works
- Primary orchestrator decomposes a goal into subtasks
- Multiple independent subagents claim and execute tasks from a shared list
- Agents are **aware of each other**, can flag dependencies, and avoid conflicts
- Agents can share context mid-task
- Centralized task list provides coordination layer

### Relationship to Other Primitives
- **Agent Teams ≠ Scripted Workflow tool** — Scripted Workflow fans out subagents deterministically (not concurrent, not aware of each other); Agent Teams allows concurrent work with inter-agent awareness
- **Agent Teams ≠ SendMessage** — SendMessage is one *communication mechanism* available *within* Agent Teams, not the teams feature itself

---

## 2. Dynamic Workflows

**Status:** Introduced May 28, 2026 (recent; treat as production-ready but monitor for evolving API)  
**Mechanic:** JavaScript coordination layer that orchestrates subagents *via code*, not model invocations

### How It Works
1. Claude reads the objective
2. Writes a short JavaScript program that defines the workflow
3. Spawns subagents and uses the code to coordinate them (direct agent-to-agent communication)
4. Agents execute tasks independently; results flow through the structured code file
5. Orchestrator synthesizes final result

### Key Innovation vs. Scripted Workflow
- **Agent-to-agent communication via code** (not through orchestrator context)
- **Orchestrator context does not fill up** with intermediate results
- **Token usage:** 60–90% reduction for complex multi-agent workflows (agents work in parallel pipelines, not strict sequence)
- **No model tokens spent** on coordination layer itself (JavaScript drives it)

### Relationship to Agent Teams
- Dynamic Workflows *replace* some Agent Teams use cases
- Dynamic Workflows are **not** the same as Agent Teams (different coordination model)
- They can be used together in hybrid patterns

---

## 3. Resumability — The Key Question

### Current State (Claude Code v2.1.77+)

**Known (from GitHub issue #35240):**
- The **`SendMessage` tool exists** and is intended for subagent resumption
- `SendMessage({to: agentId})` is documented as the way to "resume a previously spawned agent with context intact"
- **`SendMessage` is gated behind `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` flag** (disabled by default)
- In v2.1.77, the old `resume` parameter on the Agent tool was removed and replaced by SendMessage, but the migration broke the default configuration

### Does SendMessage Genuinely Resume Context?

**Known:**
- Agent tool returns `agentId` trailer, hinting to use `SendMessage(to: agentId)` to continue
- Documentation language: "continue a previously spawned agent with its context intact"
- **Limitation:** Issue #35240 confirms that by default, `SendMessage` is not available — the tool reference is broken

**Hypothesised (not yet verified from official docs):**
- SendMessage likely allows resumption of an agent that **has come to rest** (returned a result)
- Unclear whether SendMessage can message an agent that is **still running** (i.e., interactive escalation mid-task, then resume)
- Unclear whether there is any notion of long-lived agent processes or only session-scoped agents

### Interactive Escalation + Resumption

**Hypothesised:**
- No documented pattern for an agent to escalate to parent mid-task and resume where it left off
- This is the use case your autonomous-session design targets (executor → orchestrator decision gate → executor resumes)
- Agent Teams + SendMessage might enable this, but the mechanism is not explicitly documented in available sources

---

## 4. Relationship to Existing Primitives

| Tool/Feature | Scope | Resumability | Inter-agent Comms |
|---|---|---|---|
| **Agent tool** | Spawn a subagent | `SendMessage` (gated behind flag) | None (isolation) |
| **Scripted Workflow** | Fan-out deterministic subagents | None (fire-and-return) | No |
| **Agent Teams** | Concurrent subagents from shared task queue | SendMessage within teams context | Yes (teams-aware) |
| **Dynamic Workflows** | Code-driven multi-agent orchestration | (implicit via code structure) | Yes (direct, code-mediated) |
| **Task* tools** | Individual parallel tasks | None documented | None documented |

**Recommendation for long-horizon orchestration:**
- **If you need subagent escalation + resumption:** Agent Teams + SendMessage (currently experimental, gated flag, issue #35240 pending)
- **If you need token-efficient multi-agent work:** Dynamic Workflows (May 2026, new)
- **If you need deterministic fan-out:** Scripted Workflow (existing, stable, fire-and-return)

---

## 5. Bottom Line for Design

### Current Situation
Your autonomous-session design assumes **fire-and-return architecture** (subagents cannot escalate and resume; continuation is faked via artifact relay and fresh-spawn).

### Potential Path to Interactive Escalation
**Hypothetical but plausible:**
1. Enable `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` in settings
2. Form an Agent Team with executor + orchestrator subagents
3. Executor escalates mid-task via structured message to orchestrator
4. Orchestrator makes decision, sends response
5. Executor uses `SendMessage` to resume where it left off

**Blockers:**
- **Agent Teams is experimental and disabled by default** — not suitable for production autonomy harness yet
- **Issue #35240 shows SendMessage is broken in default config** — needs Anthropic to either enable SendMessage independently or fix the conditional logic
- **Unclear whether escalation mid-task is possible** — all examples show resumption after completion, not interactive back-and-forth during execution
- **Lack of official documentation** for the escalation pattern — GitHub issue is the only primary source

### Conservative Recommendation
**Stick with fire-and-return architecture for now.** 
- Agent Teams is experimental (not GA)
- SendMessage resumption is broken in default config (issue #35240)
- Dynamic Workflows are very new (May 2026); scope is token-efficient multi-agent work, not necessarily interactive escalation
- Interactive escalation + resumption is not explicitly documented in any source I found

### If You Want to Unblock This
1. File an issue on anthropics/claude-code asking: "Can SendMessage be made available independent of Agent Teams flag?" and "Is interactive escalation + resumption during execution supported?"
2. Monitor for official documentation updates on Agent Teams resumption patterns
3. When Agent Teams reaches GA and issue #35240 is resolved, experiment with a minimal executor/orchestrator pair to verify escalation works as hoped

---

## Sources & Confidence Levels

| Source | Type | Confidence |
|---|---|---|
| GitHub issue #35240 | Bug report with technical detail | HIGH — confirms SendMessage exists, is gated, and is broken by default |
| Search results (agent teams, dynamic workflows) | Blog posts, community guides | MEDIUM — secondary sources reflect announced features but not complete API docs |
| WebFetch claude.com/blog | Redirect to auth → could not fetch | LOW — wanted primary source on Dynamic Workflows launch |

---

## Open Questions for Follow-Up

1. Can `SendMessage` message an agent *while it is still running* (interactive escalation), or only *after it has returned*?
2. Does Dynamic Workflows support the escalation pattern your design needs, or is it purely for token-efficient parallel work?
3. Will Anthropic enable `SendMessage` independently of Agent Teams, or keep it gated?
4. Is there any persistence model for subagents (survive container restart, long-lived process) or only session-scoped?
5. What is the roadmap for Agent Teams to reach GA?

