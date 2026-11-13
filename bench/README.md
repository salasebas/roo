# Worksheet read benchmarks

These measurements compare the combined Ruby changes with roo 4.0.0 at `a25a8cf97e048ab1e152e5d5a70701eaa518a6bf`. They use Ruby 3.4.9, Nokogiri 1.19.7, and rubyzip 3.7.0 on an Apple M5 Pro running macOS 26.7.3. No Rust plugin is loaded.

Each case has one discarded warmup pair and five measured pairs. Every observation runs in a fresh process. Pair order alternates between baseline first and candidate first. The runner checks a SHA-256 digest of the complete result in every pair. Streaming includes a digest of each padded row's length, populated coordinates, and values.

Times include opening and the complete operation, except the two projection controls and warmed CSV. `dense-projection-loaded` loads cells and bounds before measurement. `dense-projection-warm` also runs the query once. Both then force GC. Warmed CSV runs one export before GC. Ruby startup, library loading, fixture creation, and result serialization are outside the timer. Streaming's digest consumer runs inside the timer. The filesystem cache is not cleared.

The table shows medians with minimum and maximum wall times in milliseconds. Negative reductions mean slower medians. Allocations count Ruby objects in the measured interval. Raw observations, including warmups, paired digests, GC counts, GC time, and whole-process peak RSS in bytes, are in [worksheet_reads.csv](worksheet_reads.csv). Peak RSS includes loading, prewarming, and result hashing; it is not operation-only memory.

| Case | Baseline ms [range] | Candidate ms [range] | Less time | Objects before / after |
| --- | ---: | ---: | ---: | ---: |
| `sparse-parse` | 449.455 [402.727-511.981] | 125.832 [109.945-136.074] | +72.0% | 2430743 / 400755 |
| `sparse-headers` | 1079.378 [1064.767-1091.480] | 348.050 [337.005-387.012] | +67.8% | 4411356 / 431966 |
| `sparse-each` | 1061.415 [1043.149-1068.047] | 675.437 [661.706-721.721] | +36.4% | 4411356 / 2401364 |
| `sparse-csv` | 338.898 [335.731-348.844] | 166.951 [164.392-171.241] | +50.7% | 1294027 / 524296 |
| `narrow-cells` | 358.542 [346.027-365.514] | 362.176 [353.808-372.527] | -1.0% | 1142592 / 1142592 |
| `wide-padding` | 289.733 [276.106-296.190] | 176.589 [166.799-178.782] | +39.1% | 482174 / 482178 |
| `dense-parse` | 942.008 [893.914-1030.989] | 903.835 [885.624-1104.263] | +4.1% | 2604615 / 2374629 |
| `dense-headers` | 1121.675 [1030.644-1230.822] | 960.520 [926.733-997.336] | +14.4% | 2784688 / 2584742 |
| `dense-csv` | 1395.280 [1197.380-1558.913] | 1335.973 [1179.771-1439.987] | +4.3% | 3774701 / 3774737 |
| `dense-csv-warm` | 360.778 [353.699-425.000] | 406.893 [339.877-560.374] | -12.8% | 1410072 / 1410083 |
| `dense-projection` | 946.519 [916.633-975.372] | 949.872 [934.708-963.460] | -0.4% | 2444727 / 2394735 |
| `dense-projection-loaded` | 19.055 [18.473-20.480] | 14.017 [12.222-15.781] | +26.4% | 80144 / 30152 |
| `dense-projection-warm` | 19.045 [17.266-22.377] | 13.832 [13.143-14.339] | +27.4% | 80103 / 30106 |
| `mixed-csv` | 2157.159 [2120.822-2274.087] | 2100.197 [1928.885-2153.624] | +2.6% | 6465466 / 6465501 |
| `small-parse` | 3.245 [2.863-87.432] | 3.464 [2.827-113.350] | -6.7% | 6557 / 6132 |
| `small-csv` | 4.000 [3.965-4.698] | 4.090 [3.812-4.274] | -2.2% | 8411 / 8449 |

The `matrix` rows above retain the first complete run. Six controls were repeated with nine measured pairs each (`controls` in the CSV):

| Case | Baseline ms [range] | Candidate ms [range] | Less time | Objects before / after |
| --- | ---: | ---: | ---: | ---: |
| `dense-csv-warm` | 352.702 [324.256-391.045] | 343.671 [319.393-386.088] | +2.6% | 1410072 / 1410083 |
| `small-parse` | 3.118 [2.866-36.262] | 2.879 [2.538-3.185] | +7.7% | 6557 / 6131 |
| `small-csv` | 4.599 [4.301-6.537] | 4.475 [4.252-4.976] | +2.7% | 8411 / 8449 |
| `narrow-cells` | 343.526 [331.655-356.009] | 359.733 [354.838-362.979] | -4.7% | 1142592 / 1142592 |
| `dense-projection-loaded` | 17.350 [16.852-17.623] | 12.681 [12.316-13.056] | +26.9% | 80144 / 30152 |
| `dense-projection-warm` | 16.885 [16.682-17.314] | 12.559 [11.990-13.581] | +25.6% | 80103 / 30106 |

The warmed dense CSV slowdown did not repeat. The narrow read was 16.2 ms slower in the repeat, with identical allocations but five major collections instead of four in every measured candidate process. The parser code is unchanged; these results still prevent a claim of no performance regressions.

After fixing CSV output with mixed string encodings, the affected sparse CSV case was measured again with five pairs (`post-review`): 309.384 ms [281.284-425.728] became 140.789 ms [139.341-165.488], or 54.5% less time. Allocations remained 1,294,027 before and 524,296 after. Every paired result matched in all three runs.

## Scope

Complete-row `parse` fills the final rows from stored cells. Named projections keep selected-column reads. Header iteration resolves the current sheet for each yielded row and observes callback edits. CSV uses the existing field formatter and skips missing coordinates only when stored cells occupy less than half of the output rectangle. Dense CSV uses the existing writer. Streaming fills positive integer padding gaps with `Array.new`.

The XML cell parser is unchanged. The separate traversal experiment shifted a GC pause into the first query after loading a worksheet. That experiment was removed from this change rather than adjusting GC settings. The tall, narrow case remains as an unchanged-parser control. Small timing differences and overlapping ranges are not evidence of a general speedup or regression. The benchmark does not establish performance on every workbook or Ruby version.

The fixtures contain deterministic worksheet XML in a copy of `test/files/only_one_sheet.xlsx`. Sparse parsing has 10,000 rows, 200 header columns, and two populated body columns. Sparse CSV has 10,000 rows and 40 columns. Dense and mixed sheets have 10,000 rows and 20 columns. Mixed includes booleans, numbers, quoted text, and Unicode. Narrow has 30,000 rows and two columns. Padding has 10,000 rows with cells in A and SF. Small has 40 rows and eight columns.

## Reproduce

The script uses only roo's dependencies and Ruby's standard library. Export the baseline library, then run from this checkout:

```sh
roo_baseline_dir="$(mktemp -d)"
git archive a25a8cf97e048ab1e152e5d5a70701eaa518a6bf lib | tar -x -C "$roo_baseline_dir"
ruby bench/worksheet_reads.rb --baseline "$roo_baseline_dir" --pairs 5 --output /tmp/roo-worksheet-reads.json
```

Use `--scenarios sparse-parse,sparse-headers,sparse-csv` to select cases. `--candidate PATH` selects another checkout or a directory containing its `lib`. RSS is collected with `/usr/bin/time -l` on macOS. The script leaves RSS empty on other platforms.

The committed CSV was converted from the runner's JSON output. Its `run` column distinguishes the complete five-pair matrix, the nine-pair control repeat, and the five-pair CSV repeat after review. The remaining columns preserve the corresponding JSON fields; paths and repeated environment metadata are omitted.

## Correctness checks

Focused RSpec checks cover `base_spec.rb`, `excelx_spec.rb`, `excelx/`, and `strict_spec.rb`. Focused Minitest checks cover `test/roo/test_excelx.rb` and `test/formatters/test_csv.rb`. They include Hash defaults, named columns, callback edits, reader overrides, wide nil padding, unordered coordinates, and partial CSV files after errors. The default-Hash and partial-output probes fail when their corresponding guard or flush is removed.

Focused RSpec checks pass on Ruby 3.3.13 and Ruby 3.4.9: 174 examples each. Minitest passes 40 tests and 337 assertions, with three existing skips. The encoding regression test passes on the baseline, fails before the CSV fix, and passes after it. The non-integer padding test fails if the original error path is removed. The full suite runs in CI.

```sh
MT_NO_PLUGINS=1 ruby -Ilib -Ispec -S rspec spec/lib/roo/base_spec.rb spec/lib/roo/excelx_spec.rb spec/lib/roo/excelx spec/lib/roo/strict_spec.rb
MT_NO_PLUGINS=1 ruby -Ilib -Itest -e 'gem "minitest", "~>5"; require "./test/roo/test_excelx"; require "./test/formatters/test_csv"'
```

## Sources

The row-grouping approach comes from the Ruby path in [roo-calamine #14](https://github.com/salasebas/roo-calamine/pull/14). The sparse CSV traversal comes from its Ruby writer in [#29](https://github.com/salasebas/roo-calamine/pull/29). This change retains roo's own CSV field conversion instead of copying those rules. [Ruby's Array.new contract](https://docs.ruby-lang.org/en/3.4/Array.html#method-c-new) defines the nil-filled padding used here. Persistent callback indexes were rejected because direct replacement of future cells must remain visible.
