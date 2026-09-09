-- Expected results derived from source semantics, not from the candidate output.
SELECT 'null becomes zero' AS check_name, contoso.fn_demo_total(NULL) = 0 AS passed
UNION ALL SELECT 'tax on 100', contoso.fn_demo_total(100) = 120
UNION ALL SELECT 'numeric rounding', contoso.fn_demo_total(1.234) = 1.48
UNION ALL SELECT 'negative amounts', contoso.fn_demo_total(-10) = -12;
