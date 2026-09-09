-- Synthetic repair fixture, not output recovered from the historical migration.
CREATE OR REPLACE FUNCTION contoso.fn_demo_total(p_amount numeric)
RETURNS numeric LANGUAGE plpgsql AS $$
BEGIN
  RETURN round(coalesce(p_amount, 0) * 1.20, 2);
END;
$$;
