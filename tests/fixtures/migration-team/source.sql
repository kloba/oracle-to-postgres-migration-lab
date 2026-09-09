-- Synthetic Oracle source, retained for review; not executed by the PG validator.
CREATE OR REPLACE FUNCTION fn_demo_total(p_amount NUMBER) RETURN NUMBER IS
BEGIN
  RETURN ROUND(NVL(p_amount, 0) * 1.20, 2);
END;
/
