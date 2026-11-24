# KillValue

A World of Warcraft: Forever addon that tells you what every enemy is worth, in coin, items and experience.

## What it does

**Hover an enemy** and its tooltip shows:

- **Kill value**: the expected vendor value of one kill. That's the average coin plus each item's sell price × how often it drops × how many usually drop.
- A **± range** showing how sure the average is (95% confidence, from the spread of your kills). It narrows as you kill more.
- The coin / items split, and the most valuable drops with their drop chance and what each adds per kill.
- What Skinning / Pick Pocket on that enemy is worth on average, and how often you've done it.
- What you've earned from that enemy so far, and your best single kill of it.
- **Fight time:** seconds of combat per kill and **value per hour of fighting**.
- **XP per kill** at your current level, **kills to level** and **XP per hour of fighting**.

The numbers come from your own kills. For an enemy you haven't killed yet, the value is estimated from other enemies of the same level, and the XP from the 1.x experience formula.

**Every kill you loot** prints a message:

```
KillValue: Defias Thug: 5s 51c  (25c coin + 5s 26c in 3 items)  +100 XP
   this enemy: 11s 2c over 4 kills, avg 2s 75c  - all kills: total 3g 12s, avg 31s over 101 kills since reset
```

**Notable drops** are announced, optionally with a sound. That covers anything green or better, and anything rarer than 5% once you've killed that enemy at least 10 times.

**The window** (`/kv`, or the addon menu by the minimap) has eight tabs:

| Tab | Shows |
|---|---|
| Overview | Kills, total value, average per kill, coin/items split, value/XP/kills per hour played and per hour of fighting, XP and time to level, best kill, gold goal progress. Shows since-reset and all-time figures, with reset buttons. |
| Enemies | Every enemy you've killed: level, kills, average value, XP per kill, value per fight hour, total earned. Click a heading to sort. Click an enemy to see its zone, fight time, drop table (chance, average quantity, price each, value per kill) or reset that one enemy. |
| Zones | Kills, average value and XP per kill, and **value and XP per hour spent in each zone** (downtime included), to show where farming pays best. |
| Loot | Every item you've looted, since reset or all time: times looted, quantity, price each, total value. |
| Recent | Your last 200 kills with XP and value, tagged `[dungeon]` / `[group]`. |
| Sessions | Your current session and up to 100 past ones: when it started, time played, kills, value, gold and XP per hour, average per kill. A session ends when you reset (or at each login, if you choose). |
| Options | Every setting listed below. |

## Options

| Option | Default | Command |
|---|---|---|
| Chat message for each kill | on | `/kv quiet` |
| …including this enemy's totals and the overall average | on | `/kv verbose` |
| Kill value and XP on enemy tooltips | on | `/kv tooltip` |
| Count kills that drop nothing (as 0) | on | `/kv empty` |
| Count dungeon and raid enemies | on | `/kv dungeons` |
| Count kills while in a party or raid (party loot) | on | `/kv group` |
| In a group, count only your share of the coin | on | `/kv share` |
| Announce green-or-better and rare drops | on | `/kv alerts` |
| …with a sound | off | `/kv sound` |
| Item prices: vendor, or auction via Auctionator / TSM | vendor | `/kv price vendor` / `/kv price auction` |
| Gold goal | none | `/kv goal 100g` / `/kv goal clear` |
| Credit Skinning / Pick Pocket loot to the enemy | on | `/kv gather` |
| Start a new session at each login | off | `/kv sessions` |

Other commands:

- `/kv stats` prints totals, averages, per-hour rates and kills to level in chat.
- `/kv mobs [n]` lists the best-paying enemies.
- `/kv export enemies|loot|zones|recent|sessions` opens the table as CSV to copy into a spreadsheet. The Options tab has buttons for each.

**Auction prices:** with Auctionator or TradeSkillMaster installed, `/kv price auction` values items at auction price minus the 5% auction house cut, and never below their vendor price. Everything is recorded at vendor price and re-valued when it's displayed, so you can switch back and forth freely.

**Gold goal:** `/kv goal 100g` shows your current gold against the goal, plus roughly how many kills and how much playtime are left at your current pace.

**Info bars and minimap:** if you use an info-bar addon (Titan Panel, ChocolateBar, ElvUI datatexts), KillValue adds a gold-per-hour readout to it with a summary tooltip. If LibDBIcon is loaded, you also get a minimap button.
- `/kv reset` starts a new session: the old one is saved on the Sessions tab, and all-time stats are kept.
- `/kv reset mob <name>` forgets one enemy's stats.
- `/kv reset all` clears everything.

### How kills are counted

- Values are vendor sell prices.
- A kill counts toward the loot averages once you loot it. A solo kill that drops nothing counts as 0 (unless you turn that off). XP counts for every kill, looted or not.
- Skinning and Pick Pocket loot is credited to the enemy it came from, but tracked apart from its drops. Herbs, ore, fishing and chests are ignored. Re-opening a corpse isn't counted twice.
- Critters, totems, pets and enemies tapped by someone else are skipped.
- In a group, a corpse you can't loot might just be someone else's to loot, so it isn't counted as an empty kill.

## Development

```bash
lua5.1 tests/smoke.lua   # simulated kills/loot/XP against a stubbed WoW API
luacheck .
```

## Releases (automatic)

Every pull request gets a version label from its title:

| PR title starts with | Label | Version change |
|---|---|---|
| `feat:` | `release:minor` | 1.3.0 → 1.4.0 |
| `fix:` or anything else | `release:patch` | 1.3.0 → 1.3.1 |
| `feat!:` or the body says "BREAKING CHANGE" | `release:major` | 1.3.0 → 2.0.0 |
| `docs:`, `ci:`, `chore:`, `test:` | `release:skip` | no release |

To override the bump, change the label on the PR. When a PR is merged, the **Release** workflow:

1. Tests the code.
2. Tags the merge `vX.Y.Z`.
3. Builds `KillValue-vX.Y.Z.zip` with the BigWigs packager and uploads it to CurseForge.
4. Publishes a GitHub release with the zip and a changelog.

To merge, comment `/merge` on the PR (it waits for checks to pass and then starts the release), or click Merge.

### One-time setup

1. **CurseForge project**: create the project on CurseForge (game: World of Warcraft, flavor: Forever) and note its **Project ID**.
2. **API token**: get one at <https://legacy.curseforge.com/account/api-tokens>.
3. In the GitHub repo, go to **Settings → Secrets and variables → Actions**:
   - Under **Secrets**, add `CF_API_KEY` = your token.
   - Under **Variables**, add `CF_PROJECT_ID` = your project ID.
4. Go to **Settings → Actions → General → Workflow permissions** and select **Read and write permissions**.

Until steps 1 to 3 are done, releases still get tagged and published on GitHub; only the CurseForge upload is skipped.
