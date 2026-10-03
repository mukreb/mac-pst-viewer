# Test fixtures

| File | Source | License |
|------|--------|---------|
| `dist-list.pst` | [java-libpst](https://github.com/rjohnsondev/java-libpst) test resources | Apache-2.0 |
| `tika-testPST.pst`, `tika-various-body-types.pst` | [Apache Tika](https://github.com/apache/tika) test documents (via PSTD) | Apache-2.0 |
| `inline-cid.pst` | [PSTD](https://github.com/andrew3stedall/PSTD) fixtures | MIT |
| `dist-list-ansi.pst` | `dist-list.pst` converted with `scripts/make_ansi_pst.py` (ANSI, permute encryption) | Apache-2.0 |
| `netscape/` | Synthetic Netscape Communicator 4.x mail folder, written by `scripts/make_mbox_fixture.py` | MIT |
| `tika-ansi-high.pst` | `tika-testPST.pst` converted with `scripts/make_ansi_pst.py --crypt 2` (ANSI, cyclic encryption) | Apache-2.0 |

The ANSI conversions were cross-checked with libpff (`pip install libpff-python`), which reads them identically.
