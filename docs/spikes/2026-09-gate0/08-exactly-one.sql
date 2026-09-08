-- Gate 0: the commit-time "exactly one" guarantee that the partial unique
-- index cannot give. #74: "require a partial unique index on assertion ID plus
-- a commit-time guarantee for exactly one selected revision and atomic
-- switching. A partial unique index alone proves AT MOST one, not exactly one."

-- Two trigger functions, not one shared: `assertions` names the key `id` and
-- `assertion_revisions` names it `assertion_id`, and plpgsql resolves NEW.<col>
-- at run time -- a single function referencing both raises
-- `record "new" has no field "assertion_id"` on the assertions table. Found by
-- running it.
CREATE FUNCTION assertion_current_count(target bigint) RETURNS void AS $$
DECLARE
  n int;
BEGIN
  -- An assertion deleted outright takes its revisions with it; nothing to check.
  IF NOT EXISTS (SELECT 1 FROM assertions WHERE id = target) THEN
    RETURN;
  END IF;

  SELECT count(*) INTO n
    FROM assertion_revisions WHERE assertion_id = target AND is_current;

  IF n <> 1 THEN
    RAISE EXCEPTION 'assertion % has % current revisions, expected exactly 1', target, n
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION assertions_exactly_one_current() RETURNS trigger AS $$
BEGIN
  PERFORM assertion_current_count(NEW.id);
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION assertion_revisions_exactly_one_current() RETURNS trigger AS $$
BEGIN
  PERFORM assertion_current_count(COALESCE(NEW.assertion_id, OLD.assertion_id));
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER assertions_exactly_one_current
  AFTER INSERT ON assertions DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assertions_exactly_one_current();

CREATE CONSTRAINT TRIGGER assertion_revisions_exactly_one_current
  AFTER INSERT OR UPDATE OR DELETE ON assertion_revisions DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assertion_revisions_exactly_one_current();
