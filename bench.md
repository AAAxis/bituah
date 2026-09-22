## Rules vs on-device model vs hybrid

Documents: 18 (9 digital + 9 scanned). Fields: 8 per document.

| config | fields correct | wrong | field CER | field WER | sec/doc (mean) | sec/doc (max) | peak RSS | peak footprint |
|---|---|---|---|---|---|---|---|---|
| rules | 126/144 (87.5%) | 18 | 6.0% | 7.4% | 0.46 | 1.29 | 672 MB | 795 MB |
| model | 132/144 (91.7%) | 12 | 3.1% | 4.9% | 3.23 | 4.74 | 283 MB | 798 MB |
| hybrid | 131/144 (91.0%) | 13 | 2.8% | 5.2% | 3.14 | 4.61 | 355 MB | 798 MB |

Peak memory is the `bituah` process (via `/usr/bin/time -l`). Apple's Foundation Model runs in a system service, so its weights are not attributable to the app; see README.

### Per document

| document | rules | model | hybrid |
|---|---|---|---|
| test_policy_1_harel_health.pdf | 8/8, 0.0s | 8/8, 4.7s | 8/8, 3.0s |
| scan_test_policy_1_harel_health.pdf | 8/8, 1.3s | 8/8, 4.2s | 8/8, 4.6s |
| test_policy_2_migdal_auto.pdf | 8/8, 0.0s | 8/8, 2.9s | 8/8, 2.9s |
| scan_test_policy_2_migdal_auto.pdf | 8/8, 1.1s | 8/8, 3.9s | 8/8, 3.9s |
| test_policy_3_phoenix_life.pdf | 8/8, 0.0s | 8/8, 3.1s | 8/8, 3.1s |
| scan_test_policy_3_phoenix_life.pdf | 8/8, 1.0s | 8/8, 3.7s | 8/8, 3.7s |
| extra_1_menora_home.pdf | 8/8, 0.0s | 7/8, 2.7s ❌ monthly_premium_ils | 7/8, 2.7s ❌ monthly_premium_ils |
| scan_extra_1_menora_home.pdf | 7/8, 0.8s ❌ company_name | 6/8, 3.5s ❌ company_name, monthly_premium_ils | 6/8, 3.5s ❌ company_name, monthly_premium_ils |
| extra_2_clal_pension.pdf | 5/8, 0.0s ❌ policy_number, start_date, monthly_premium_ils | 7/8, 2.6s ❌ start_date | 7/8, 2.6s ❌ start_date |
| scan_extra_2_clal_pension.pdf | 4/8, 0.8s ❌ company_name, policy_number, start_date, monthly_premium_ils | 6/8, 3.4s ❌ company_name, start_date | 6/8, 3.2s ❌ company_name, start_date |
| extra_3_ayalon_auto.pdf | 7/8, 0.0s ❌ monthly_premium_ils | 7/8, 2.5s ❌ monthly_premium_ils | 7/8, 2.4s ❌ monthly_premium_ils |
| scan_extra_3_ayalon_auto.pdf | 6/8, 0.7s ❌ company_name, monthly_premium_ils | 7/8, 3.1s ❌ monthly_premium_ils | 7/8, 3.2s ❌ monthly_premium_ils |
| extra_4_phoenix_ltc.pdf | 7/8, 0.0s ❌ policy_number | 7/8, 2.5s ❌ insured_id | 8/8, 2.7s |
| scan_extra_4_phoenix_ltc.pdf | 6/8, 0.8s ❌ company_name, policy_number | 6/8, 3.1s ❌ company_name, deductible_ils | 6/8, 3.1s ❌ company_name, deductible_ils |
| extra_5_harel_health_table.pdf | 7/8, 0.0s ❌ monthly_premium_ils | 8/8, 2.5s | 7/8, 2.6s ❌ monthly_premium_ils |
| scan_extra_5_harel_health_table.pdf | 6/8, 0.8s ❌ company_name, monthly_premium_ils | 8/8, 3.9s | 7/8, 3.5s ❌ monthly_premium_ils |
| extra_6_migdal_life.pdf | 8/8, 0.0s | 8/8, 2.6s | 8/8, 2.6s |
| scan_extra_6_migdal_life.pdf | 7/8, 0.8s ❌ company_name | 7/8, 3.3s ❌ company_name | 7/8, 3.3s ❌ company_name |

### model vs rules

**Won (10)**
- extra_2_clal_pension.pdf · policy_number: rules `null` → model `"8837201-55"`
- extra_2_clal_pension.pdf · monthly_premium_ils: rules `null` → model `1250.0`
- scan_extra_2_clal_pension.pdf · policy_number: rules `null` → model `"8837201-55"`
- scan_extra_2_clal_pension.pdf · monthly_premium_ils: rules `null` → model `1250.0`
- scan_extra_3_ayalon_auto.pdf · company_name: rules `"איילון חברה לביטוח בע\"ימ"` → model `"איילון חברה לביטוח בע\"מ"`
- extra_4_phoenix_ltc.pdf · policy_number: rules `null` → model `"7710-2299-31"`
- scan_extra_4_phoenix_ltc.pdf · policy_number: rules `"15/07/2025-0"` → model `"7710-2299-31"`
- extra_5_harel_health_table.pdf · monthly_premium_ils: rules `300.0` → model `270.0`
- scan_extra_5_harel_health_table.pdf · company_name: rules `"הראל חברה לביטוח בע\"\"מ"` → model `"הראל חברה לביטוח בע\"מ"`
- scan_extra_5_harel_health_table.pdf · monthly_premium_ils: rules `300.0` → model `270.0`

**Lost (4)**
- extra_1_menora_home.pdf · monthly_premium_ils: rules `220.0` → model `2640.0`
- scan_extra_1_menora_home.pdf · monthly_premium_ils: rules `220.0` → model `2640.0`
- extra_4_phoenix_ltc.pdf · insured_id: rules `"028765432"` → model `null`
- scan_extra_4_phoenix_ltc.pdf · deductible_ils: rules `null` → model `0.0`

### hybrid vs rules

**Won (8)**
- extra_2_clal_pension.pdf · policy_number: rules `null` → hybrid `"8837201-55"`
- extra_2_clal_pension.pdf · monthly_premium_ils: rules `null` → hybrid `1250.0`
- scan_extra_2_clal_pension.pdf · policy_number: rules `null` → hybrid `"8837201-55"`
- scan_extra_2_clal_pension.pdf · monthly_premium_ils: rules `null` → hybrid `1250.0`
- scan_extra_3_ayalon_auto.pdf · company_name: rules `"איילון חברה לביטוח בע\"ימ"` → hybrid `"איילון חברה לביטוח בע\"מ"`
- extra_4_phoenix_ltc.pdf · policy_number: rules `null` → hybrid `"7710-2299-31"`
- scan_extra_4_phoenix_ltc.pdf · policy_number: rules `"15/07/2025-0"` → hybrid `"7710-2299-31"`
- scan_extra_5_harel_health_table.pdf · company_name: rules `"הראל חברה לביטוח בע\"\"מ"` → hybrid `"הראל חברה לביטוח בע\"מ"`

**Lost (3)**
- extra_1_menora_home.pdf · monthly_premium_ils: rules `220.0` → hybrid `2640.0`
- scan_extra_1_menora_home.pdf · monthly_premium_ils: rules `220.0` → hybrid `2640.0`
- scan_extra_4_phoenix_ltc.pdf · deductible_ils: rules `null` → hybrid `0.0`
