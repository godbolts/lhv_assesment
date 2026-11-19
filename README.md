# AFC committee memo: TM-07 tuning (Proposal A) and risk model v4 (Proposal B)

## Part 1: Recommendation

### A1. Proposal A: tune TM-07

**Recommendation:** approve the own-account exclusion, but reject the threshold increase.

Rebuilding the rule gave this overview of the data, showing that the changes to the threshold immensely effect the true positive capture rate:

| Variant | Alerts in 12 months | Per month | True positives kept (of 66) |
| --- | --- | --- | --- |
| TM-07 today | 1,251 | ~104 | 66 |
| Proposal A (both changes) | 418 | ~35 | 38 |
| Threshold €25,000 only | 538 | ~45 | 39 |
| Own-account exclusion only | 870 | ~73 | 66 |

- The proposal cuts alert volume, but loses almost half of the true positives.
- Excluding own-account transfers removes 381 alerts and keeps true positives.
  
### A2. Threshold lowered to €10,000

- Adds 309 alerts over 12 months, a +25% increase.
- No idea how many additional cases it would catch because the alerts have not been analyst reviewed.
- The closest evidence is that the upper band on 15,000€ to 25,000€ supplies true positives by about 3%, so a lower band would probably be similar.

### B1. Proposal B: risk model v4

**Recommendation:** do not approve it as it is currently.

Should the change be implemented:

- 189 clients change band, and all move upward.
- 35 clients become a High risk client in a day.
- 35 EDD reviews cannot be absorbed by a team that has a monthly 10 review capacity.

## Part 2: Data issues (ranked by effect on these decisions)

| # | Issue | Changes the answer? |
| --- | --- | --- |
| 1 | **30 September factor scores loaded twice** (two identical batches on 1 October). | Yes, completely, if missed. Fixed by keeping one row per customer and factor; recalculated totals then match `risk_snapshot` for all 5,885 customers. |
| 2 | **`monitoring_alerts` is a status history**: 2–3 rows per TM-07 alert (NEW, IN_REVIEW, closed). | Yes: counting rows overstates TM-07 volume almost 3×. Fixed by taking each alert's latest status. |
| 3 | **Faulty TM-07 run in February 2026**: 400 extra alerts closed as `CLOSED_TECHNICALLY_INCORRECT`, a status missing from `alert_statuses`. None meets the rule (highest monthly sum ~€12,300). | If included February shows 512 alerts instead of ~100 and the false-positive problem looks worse. |
| 4 | **F09 cannot track the country that money was sent to** `counterparty_country` is filled on ~0.3% of rows, so the bank's country is used. | Not too much, but it means that F09 understates. |



## Part 3: Making this repeatable

I would build parameter tables to manage the changing variables in production and then build the data quality and outcome queries as existing reports in PowerBi

## What I would do next

- Back-test v4 over more historic data to better predict HIGH risk inflow.
