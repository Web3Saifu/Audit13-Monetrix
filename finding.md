❗ 1. Yield movement bypasses Accountant gates (IMPORTANT)
📄 Docs say:

INV-5 → INV-9:

Yield must go through:

settleDailyPnL → 4 gates
❗ But in code:
function bridgeYieldFromL1(uint256 amount)

👉 This happens BEFORE settle

It only checks:

require(amount <= yieldShortfall())
🚨 Problem:

👉 You are moving “yield” WITHOUT passing 4-gate validation

🔥 Real Question:

“Can funds be classified as yield before Accountant approval?”

👉 Answer: YES

⚠️ Conclusion:

❌ Developer breaks strict yield pipeline assumption

❗ 2. yieldShortfall() ≠ documented “surplus discipline”
📄 Docs say:
distributableSurplus = surplus - shortfall
❗ But contract uses:
yieldShortfall = surplus - availableVaultBalance

👉 These are NOT the same thing.

🔥 Problem:
Docs: yield limited by global system solvency
Code: yield limited by local vault liquidity
⚠️ Result:

❌ Misalignment between:

Accounting logic (docs)
Execution logic (contract)
❗ 3. No guarantee yield is “realized” (DOC CLAIM BREAK)
📄 Docs say:

Yield comes from funding, lending, HLP, etc.

❗ But contract:
_sendL1Bridge(amount)

👉 Only checks:

L1 balance
NOT:
whether yield is realized
whether positions are closed
🔥 Problem:

Yield may exist in accounting but NOT withdrawable

⚠️ Result:

❌ Breaks assumption:

“Yield is usable capital”

❗ 4. Principal vs Yield separation NOT enforced
📄 Docs say:

Backing includes:

Spot
Perp PnL
HLP
etc.
❗ But in contract:
outstandingL1Principal

is tracked

BUT:

bridgeYieldFromL1

👉 does NOT update or validate against it

🔥 Problem:

Nothing ensures bridged amount is truly “yield”

⚠️ Result:

❌ Potential invariant violation:

INV-1 (backing vs supply)

❗ 5. Operator trust assumption leaks into core logic
📄 Docs say:

Operator is trusted (known issue)

❗ But implementation relies on Operator to:
choose correct amount
respect yield boundaries
🔥 Problem:

Even though “trusted”:

contract still exposes unsafe surface
⚠️ Result:

❌ Weak enforcement of invariants in code

❗ 6. Missing linkage to 4-gate system (design inconsistency)
📄 Docs strongly emphasize:

Accountant is central authority

❗ But:
bridgeYieldFromL1

👉 does NOT call:

settleDailyPnL
OR any gate check
🔥 Problem:

Two parallel systems exist:

Accountant (strict rules)
Bridge (loose rules)
⚠️ Result:

❌ Architectural inconsistency

❗ 7. Yield can get stuck (violates “all-weather yield” claim)
📄 Docs say:

“All-weather yield… always positive”

❗ But:
if (yield <= available) return 0;
Scenario:
Vault already has enough balance
L1 still has yield

👉 yieldShortfall = 0

👉 Cannot bridge

⚠️ Result:

❌ Yield stuck → contradicts doc narrative

❗ 8. No invariant enforcement during bridge

Docs define:

INV-1:
totalBacking ≥ totalSupply
❗ But:

bridgeYieldFromL1 does NOT check:

backing
solvency
system state
⚠️ Result:

❌ Missing invariant enforcement at critical step