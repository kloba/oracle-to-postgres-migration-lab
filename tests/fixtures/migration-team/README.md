# Migration-team smoke fixtures

These files are synthetic inputs for the new team workflow, **not** recovered
artifacts from the September 4 conversion. `source.sql` is an Oracle function;
`candidate.sql` is its small PostgreSQL counterpart; `checks.sql` checks nulls,
rounding, a positive value and a negative value. The disposable validator executes
only the PostgreSQL SQL. It does not query Oracle or certify Oracle equivalence.

The two CSV exports hold identical synthetic values in different row/column orders.
`__NULL__` is an explicit export convention, not a magic value in the comparator.
The comparator preserves it as text and does not silently equate it with an empty
string. See [the Copilot team guide](../../../docs/06-copilot-migration-team.md).
