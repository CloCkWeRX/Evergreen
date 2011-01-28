
BEGIN;
-- NOTE: current config.item_type should get sip2_media_type and magnetic_media columns

-- New table needed to handle circ modifiers inside the DB.  Will still require
-- central admin.  The circ_modifier column on asset.copy will become an fkey to this table.
CREATE TABLE config.circ_modifier (
    code            TEXT    PRIMARY KEY,
    name            TEXT    UNIQUE NOT NULL,
    description        TEXT    NOT NULL,
    sip2_media_type    TEXT    NOT NULL,
    magnetic_media     BOOL    NOT NULL DEFAULT TRUE,
    avg_wait_time      INTERVAL
);

/*
-- for instance ...
INSERT INTO config.circ_modifier VALUES ( 'DVD', 'DVD', 'um ... DVDs', '001', FALSE );
INSERT INTO config.circ_modifier VALUES ( 'VIDEO', 'VIDEO', 'Tapes', '001', TRUE );
INSERT INTO config.circ_modifier VALUES ( 'BOOK', 'BOOK', 'Dead tree', '001', FALSE );
INSERT INTO config.circ_modifier VALUES ( 'CRAZY_ARL-ATH_SETTING', 'R2R_TAPE', 'reel2reel tape', '007', TRUE );
*/

-- But, just to get us started, use this
/*

UPDATE asset.copy SET circ_modifier = UPPER(circ_modifier) WHERE circ_modifier IS NOT NULL AND circ_modifier <> '';
UPDATE asset.copy SET circ_modifier = NULL WHERE circ_modifier = '';

INSERT INTO config.circ_modifier (code, name, description, sip2_media_type )
    SELECT DISTINCT
            UPPER(circ_modifier),
            UPPER(circ_modifier),
            LOWER(circ_modifier),
            '001'
      FROM  asset.copy
      WHERE circ_modifier IS NOT NULL;

*/

-- add an fkey pointing to the new circ mod table
ALTER TABLE asset.copy ADD CONSTRAINT circ_mod_fkey FOREIGN KEY (circ_modifier) REFERENCES config.circ_modifier (code) ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;

-- config table to hold the vr_format names
CREATE TABLE config.videorecording_format_map (
    code    TEXT    PRIMARY KEY,
    value    TEXT    NOT NULL
);

INSERT INTO config.videorecording_format_map VALUES ('a','Beta');
INSERT INTO config.videorecording_format_map VALUES ('b','VHS');
INSERT INTO config.videorecording_format_map VALUES ('c','U-matic');
INSERT INTO config.videorecording_format_map VALUES ('d','EIAJ');
INSERT INTO config.videorecording_format_map VALUES ('e','Type C');
INSERT INTO config.videorecording_format_map VALUES ('f','Quadruplex');
INSERT INTO config.videorecording_format_map VALUES ('g','Laserdisc');
INSERT INTO config.videorecording_format_map VALUES ('h','CED');
INSERT INTO config.videorecording_format_map VALUES ('i','Betacam');
INSERT INTO config.videorecording_format_map VALUES ('j','Betacam SP');
INSERT INTO config.videorecording_format_map VALUES ('k','Super-VHS');
INSERT INTO config.videorecording_format_map VALUES ('m','M-II');
INSERT INTO config.videorecording_format_map VALUES ('o','D-2');
INSERT INTO config.videorecording_format_map VALUES ('p','8 mm.');
INSERT INTO config.videorecording_format_map VALUES ('q','Hi-8 mm.');
INSERT INTO config.videorecording_format_map VALUES ('u','Unknown');
INSERT INTO config.videorecording_format_map VALUES ('v','DVD');
INSERT INTO config.videorecording_format_map VALUES ('z','Other');



/**
 **  Here we define the tables that make up the circ matrix.  Conceptually, this implements
 **  the "sparse matrix" that everyone talks about, instead of using traditional rules logic.
 **  Physically, we cut the matrix up into separate tables (almost 3rd normal form!) that handle
 **  different portions of the matrix.  This wil simplify creation of the UI (I hope), and help the
 **  developers focus on specific parts of the matrix.
 **/

CREATE TABLE config.circ_matrix_matchpoint (
    id                   SERIAL    PRIMARY KEY,
    active               BOOL    NOT NULL DEFAULT TRUE,
    org_unit             INT        NOT NULL REFERENCES actor.org_unit (id) DEFERRABLE INITIALLY DEFERRED,    -- Set to the top OU for the matchpoint applicability range; we can use org_unit_prox to choose the "best"
    grp                  INT     NOT NULL REFERENCES permission.grp_tree (id) DEFERRABLE INITIALLY DEFERRED,    -- Set to the top applicable group from the group tree; will need descendents and prox functions for filtering
    circ_modifier        TEXT    REFERENCES config.circ_modifier (code) DEFERRABLE INITIALLY DEFERRED,
    marc_type            TEXT    REFERENCES config.item_type_map (code) DEFERRABLE INITIALLY DEFERRED,
    marc_form            TEXT    REFERENCES config.item_form_map (code) DEFERRABLE INITIALLY DEFERRED,
    marc_vr_format       TEXT    REFERENCES config.videorecording_format_map (code) DEFERRABLE INITIALLY DEFERRED,
    copy_circ_lib        INT     REFERENCES actor.org_unit (id) DEFERRABLE INITIALLY DEFERRED,
    copy_owning_lib      INT     REFERENCES actor.org_unit (id) DEFERRABLE INITIALLY DEFERRED,
    user_home_ou         INT     REFERENCES actor.org_unit (id) DEFERRABLE INITIALLY DEFERRED,
    ref_flag             BOOL,
    juvenile_flag        BOOL,
    is_renewal           BOOL,
    usr_age_lower_bound  INTERVAL,
    usr_age_upper_bound  INTERVAL,
    circulate            BOOL    NOT NULL DEFAULT TRUE,    -- Hard "can't circ" flag requiring an override
    duration_rule        INT     NOT NULL REFERENCES config.rule_circ_duration (id) DEFERRABLE INITIALLY DEFERRED,
    recurring_fine_rule  INT     NOT NULL REFERENCES config.rule_recurring_fine (id) DEFERRABLE INITIALLY DEFERRED,
    max_fine_rule        INT     NOT NULL REFERENCES config.rule_max_fine (id) DEFERRABLE INITIALLY DEFERRED,
    hard_due_date        INT     REFERENCES config.hard_due_date (id) DEFERRABLE INITIALLY DEFERRED,
    script_test          TEXT,                           -- javascript source 
    total_copy_hold_ratio     FLOAT,
    available_copy_hold_ratio FLOAT,
    CONSTRAINT ep_once_per_grp_loc_mod_marc UNIQUE (
        grp, org_unit, circ_modifier, marc_type, marc_form, marc_vr_format, ref_flag,
        juvenile_flag, usr_age_lower_bound, usr_age_upper_bound, is_renewal, copy_circ_lib,
        copy_owning_lib
    )
);


-- Tests for max items out by circ_modifier
CREATE TABLE config.circ_matrix_circ_mod_test (
    id          SERIAL     PRIMARY KEY,
    matchpoint  INT     NOT NULL REFERENCES config.circ_matrix_matchpoint (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    items_out   INT     NOT NULL -- Total current active circulations must be less than this, NULL means skip (always pass)
);

CREATE TABLE config.circ_matrix_circ_mod_test_map (
    id      SERIAL  PRIMARY KEY,
    circ_mod_test   INT NOT NULL REFERENCES config.circ_matrix_circ_mod_test (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    circ_mod        TEXT    NOT NULL REFERENCES config.circ_modifier (code) ON DELETE CASCADE ON UPDATE CASCADE  DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT cm_once_per_test UNIQUE (circ_mod_test, circ_mod)
);

CREATE OR REPLACE FUNCTION action.find_circ_matrix_matchpoint( context_ou INT, match_item BIGINT, match_user INT, renewal BOOL ) RETURNS config.circ_matrix_matchpoint AS $func$
DECLARE
    user_object     actor.usr%ROWTYPE;
    item_object     asset.copy%ROWTYPE;
    cn_object       asset.call_number%ROWTYPE;
    rec_descriptor  metabib.rec_descriptor%ROWTYPE;
    matchpoint      config.circ_matrix_matchpoint%ROWTYPE;
    weights         config.circ_matrix_weights%ROWTYPE;
    user_age        INTERVAL;
    denominator     INT;
BEGIN
    SELECT INTO user_object     * FROM actor.usr                WHERE id = match_user;
    SELECT INTO item_object     * FROM asset.copy               WHERE id = match_item;
    SELECT INTO cn_object       * FROM asset.call_number        WHERE id = item_object.call_number;
    SELECT INTO rec_descriptor  * FROM metabib.rec_descriptor   WHERE record = cn_object.record;

    -- Pre-generate this so we only calc it once
    IF user_object.dob IS NOT NULL THEN
        SELECT INTO user_age age(user_object.dob);
    END IF;

    -- Grab the closest set circ weight setting.
    SELECT INTO weights cw.*
      FROM config.weight_assoc wa
           JOIN config.circ_matrix_weights cw ON (cw.id = wa.circ_weights)
           JOIN actor.org_unit_ancestors_distance( context_ou ) d ON (wa.org_unit = d.id)
      WHERE active
      ORDER BY d.distance
      LIMIT 1;

    -- No weights? Bad admin! Defaults to handle that anyway.
    IF weights.id IS NULL THEN
        weights.grp                 := 11;
        weights.org_unit            := 10;
        weights.circ_modifier       := 5;
        weights.marc_type           := 4;
        weights.marc_form           := 3;
        weights.marc_vr_format      := 2;
        weights.copy_circ_lib       := 8;
        weights.copy_owning_lib     := 8;
        weights.user_home_ou        := 8;
        weights.ref_flag            := 1;
        weights.juvenile_flag       := 6;
        weights.is_renewal          := 7;
        weights.usr_age_lower_bound := 0;
        weights.usr_age_upper_bound := 0;
    END IF;

    -- Determine the max (expected) depth (+1) of the org tree and max depth of the permisson tree
    -- If you break your org tree with funky parenting this may be wrong
    -- Note: This CTE is duplicated in the find_hold_matrix_matchpoint function, and it may be a good idea to split it off to a function
    -- We use one denominator for all tree-based checks for when permission groups and org units have the same weighting
    WITH all_distance(distance) AS (
            SELECT depth AS distance FROM actor.org_unit_type
        UNION
       	    SELECT distance AS distance FROM permission.grp_ancestors_distance((SELECT id FROM permission.grp_tree WHERE parent IS NULL))
	)
    SELECT INTO denominator MAX(distance) + 1 FROM all_distance;

    -- Select the winning matchpoint into the matchpoint variable for returning
    SELECT INTO matchpoint m.*
      FROM  config.circ_matrix_matchpoint m
            /*LEFT*/ JOIN permission.grp_ancestors_distance( user_object.profile ) upgad ON m.grp = upgad.id
            /*LEFT*/ JOIN actor.org_unit_ancestors_distance( context_ou ) ctoua ON m.org_unit = ctoua.id
            LEFT JOIN actor.org_unit_ancestors_distance( cn_object.owning_lib ) cnoua ON m.copy_owning_lib = cnoua.id
            LEFT JOIN actor.org_unit_ancestors_distance( item_object.circ_lib ) iooua ON m.copy_circ_lib = iooua.id
            LEFT JOIN actor.org_unit_ancestors_distance( user_object.home_ou  ) uhoua ON m.user_home_ou = uhoua.id
      WHERE m.active
            -- Permission Groups
         -- AND (m.grp                      IS NULL OR upgad.id IS NOT NULL) -- Optional Permission Group?
            -- Org Units
         -- AND (m.org_unit                 IS NULL OR ctoua.id IS NOT NULL) -- Optional Org Unit?
            AND (m.copy_owning_lib          IS NULL OR cnoua.id IS NOT NULL)
            AND (m.copy_circ_lib            IS NULL OR iooua.id IS NOT NULL)
            AND (m.user_home_ou             IS NULL OR uhoua.id IS NOT NULL)
            -- Circ Type
            AND (m.is_renewal               IS NULL OR m.is_renewal = renewal)
            -- Static User Checks
            AND (m.juvenile_flag            IS NULL OR m.juvenile_flag = user_object.juvenile)
            AND (m.usr_age_lower_bound      IS NULL OR (user_age IS NOT NULL AND m.usr_age_lower_bound < user_age))
            AND (m.usr_age_upper_bound      IS NULL OR (user_age IS NOT NULL AND m.usr_age_upper_bound > user_age))
            -- Static Item Checks
            AND (m.circ_modifier            IS NULL OR m.circ_modifier = item_object.circ_modifier)
            AND (m.marc_type                IS NULL OR m.marc_type = COALESCE(item_object.circ_as_type, rec_descriptor.item_type))
            AND (m.marc_form                IS NULL OR m.marc_form = rec_descriptor.item_form)
            AND (m.marc_vr_format           IS NULL OR m.marc_vr_format = rec_descriptor.vr_format)
            AND (m.ref_flag                 IS NULL OR m.ref_flag = item_object.ref)
      ORDER BY
            -- Permission Groups
            CASE WHEN upgad.distance        IS NOT NULL THEN 2^(2*weights.grp - (upgad.distance/denominator)) ELSE 0 END +
            -- Org Units
            CASE WHEN ctoua.distance        IS NOT NULL THEN 2^(2*weights.org_unit - (ctoua.distance/denominator)) ELSE 0 END +
            CASE WHEN cnoua.distance        IS NOT NULL THEN 2^(2*weights.copy_owning_lib - (cnoua.distance/denominator)) ELSE 0 END +
            CASE WHEN iooua.distance        IS NOT NULL THEN 2^(2*weights.copy_circ_lib - (iooua.distance/denominator)) ELSE 0 END +
            CASE WHEN uhoua.distance        IS NOT NULL THEN 2^(2*weights.user_home_ou - (uhoua.distance/denominator)) ELSE 0 END +
            -- Circ Type                    -- Note: 4^x is equiv to 2^(2*x)
            CASE WHEN m.is_renewal          IS NOT NULL THEN 4^weights.is_renewal ELSE 0 END +
            -- Static User Checks
            CASE WHEN m.juvenile_flag       IS NOT NULL THEN 4^weights.juvenile_flag ELSE 0 END +
            CASE WHEN m.usr_age_lower_bound IS NOT NULL THEN 4^weights.usr_age_lower_bound ELSE 0 END +
            CASE WHEN m.usr_age_upper_bound IS NOT NULL THEN 4^weights.usr_age_upper_bound ELSE 0 END +
            -- Static Item Checks
            CASE WHEN m.circ_modifier       IS NOT NULL THEN 4^weights.circ_modifier ELSE 0 END +
            CASE WHEN m.marc_type           IS NOT NULL THEN 4^weights.marc_type ELSE 0 END +
            CASE WHEN m.marc_form           IS NOT NULL THEN 4^weights.marc_form ELSE 0 END +
            CASE WHEN m.marc_vr_format      IS NOT NULL THEN 4^weights.marc_vr_format ELSE 0 END +
            CASE WHEN m.ref_flag            IS NOT NULL THEN 4^weights.ref_flag ELSE 0 END DESC,
            -- Final sort on id, so that if two rules have the same sorting in the previous sort they have a defined order
            -- This prevents "we changed the table order by updating a rule, and we started getting different results"
            m.id;

    -- Return the entire matchpoint
    RETURN matchpoint;
END;
$func$ LANGUAGE plpgsql;

CREATE TYPE action.hold_stats AS (
    hold_count              INT,
    copy_count              INT,
    available_count         INT,
    total_copy_ratio        FLOAT,
    available_copy_ratio    FLOAT
);

CREATE OR REPLACE FUNCTION action.copy_related_hold_stats (copy_id INT) RETURNS action.hold_stats AS $func$
DECLARE
    output          action.hold_stats%ROWTYPE;
    hold_count      INT := 0;
    copy_count      INT := 0;
    available_count INT := 0;
    hold_map_data   RECORD;
BEGIN

    output.hold_count := 0;
    output.copy_count := 0;
    output.available_count := 0;

    SELECT  COUNT( DISTINCT m.hold ) INTO hold_count
      FROM  action.hold_copy_map m
            JOIN action.hold_request h ON (m.hold = h.id)
      WHERE m.target_copy = copy_id
            AND NOT h.frozen;

    output.hold_count := hold_count;

    IF output.hold_count > 0 THEN
        FOR hold_map_data IN
            SELECT  DISTINCT m.target_copy,
                    acp.status
              FROM  action.hold_copy_map m
                    JOIN asset.copy acp ON (m.target_copy = acp.id)
                    JOIN action.hold_request h ON (m.hold = h.id)
              WHERE m.hold IN ( SELECT DISTINCT hold FROM action.hold_copy_map WHERE target_copy = copy_id ) AND NOT h.frozen
        LOOP
            output.copy_count := output.copy_count + 1;
            IF hold_map_data.status IN (0,7,12) THEN
                output.available_count := output.available_count + 1;
            END IF;
        END LOOP;
        output.total_copy_ratio = output.copy_count::FLOAT / output.hold_count::FLOAT;
        output.available_copy_ratio = output.available_count::FLOAT / output.hold_count::FLOAT;

    END IF;

    RETURN output;

END;
$func$ LANGUAGE PLPGSQL;

CREATE TYPE action.matrix_test_result AS ( success BOOL, matchpoint INT, fail_part TEXT );
CREATE OR REPLACE FUNCTION action.item_user_circ_test( circ_ou INT, match_item BIGINT, match_user INT, renewal BOOL ) RETURNS SETOF action.matrix_test_result AS $func$
DECLARE
    user_object        actor.usr%ROWTYPE;
    standing_penalty    config.standing_penalty%ROWTYPE;
    item_object        asset.copy%ROWTYPE;
    item_status_object    config.copy_status%ROWTYPE;
    item_location_object    asset.copy_location%ROWTYPE;
    result            action.matrix_test_result;
    circ_test        config.circ_matrix_matchpoint%ROWTYPE;
    out_by_circ_mod        config.circ_matrix_circ_mod_test%ROWTYPE;
    circ_mod_map        config.circ_matrix_circ_mod_test_map%ROWTYPE;
    hold_ratio          action.hold_stats%ROWTYPE;
    penalty_type         TEXT;
    tmp_grp         INT;
    items_out        INT;
    context_org_list        INT[];
    done            BOOL := FALSE;
BEGIN
    result.success := TRUE;

    -- Fail if the user is BARRED
    SELECT INTO user_object * FROM actor.usr WHERE id = match_user;

    -- Fail if we couldn't find the user 
    IF user_object.id IS NULL THEN
        result.fail_part := 'no_user';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
        RETURN;
    END IF;

    SELECT INTO item_object * FROM asset.copy WHERE id = match_item;

    -- Fail if we couldn't find the item 
    IF item_object.id IS NULL THEN
        result.fail_part := 'no_item';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
        RETURN;
    END IF;

    SELECT INTO circ_test * FROM action.find_circ_matrix_matchpoint(circ_ou, match_item, match_user, renewal);
    result.matchpoint := circ_test.id;

    -- Fail if we couldn't find a matchpoint
    IF result.matchpoint IS NULL THEN
        result.fail_part := 'no_matchpoint';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    IF user_object.barred IS TRUE THEN
        result.fail_part := 'actor.usr.barred';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item can't circulate
    IF item_object.circulate IS FALSE THEN
        result.fail_part := 'asset.copy.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item isn't in a circulateable status on a non-renewal
    IF NOT renewal AND item_object.status NOT IN ( 0, 7, 8 ) THEN 
        result.fail_part := 'asset.copy.status';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    ELSIF renewal AND item_object.status <> 1 THEN
        result.fail_part := 'asset.copy.status';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item can't circulate because of the shelving location
    SELECT INTO item_location_object * FROM asset.copy_location WHERE id = item_object.location;
    IF item_location_object.circulate IS FALSE THEN
        result.fail_part := 'asset.copy_location.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    SELECT INTO context_org_list ARRAY_ACCUM(id) FROM actor.org_unit_full_path( circ_test.org_unit );

    -- Fail if the test is set to hard non-circulating
    IF circ_test.circulate IS FALSE THEN
        result.fail_part := 'config.circ_matrix_test.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the total copy-hold ratio is too low
    IF circ_test.total_copy_hold_ratio IS NOT NULL THEN
        SELECT INTO hold_ratio * FROM action.copy_related_hold_stats(match_item);
        IF hold_ratio.total_copy_ratio IS NOT NULL AND hold_ratio.total_copy_ratio < circ_test.total_copy_hold_ratio THEN
            result.fail_part := 'config.circ_matrix_test.total_copy_hold_ratio';
            result.success := FALSE;
            done := TRUE;
            RETURN NEXT result;
        END IF;
    END IF;

    -- Fail if the available copy-hold ratio is too low
    IF circ_test.available_copy_hold_ratio IS NOT NULL THEN
        SELECT INTO hold_ratio * FROM action.copy_related_hold_stats(match_item);
        IF hold_ratio.available_copy_ratio IS NOT NULL AND hold_ratio.available_copy_ratio < circ_test.available_copy_hold_ratio THEN
            result.fail_part := 'config.circ_matrix_test.available_copy_hold_ratio';
            result.success := FALSE;
            done := TRUE;
            RETURN NEXT result;
        END IF;
    END IF;

    IF renewal THEN
        penalty_type = '%RENEW%';
    ELSE
        penalty_type = '%CIRC%';
    END IF;

    FOR standing_penalty IN
        SELECT  DISTINCT csp.*
          FROM  actor.usr_standing_penalty usp
                JOIN config.standing_penalty csp ON (csp.id = usp.standing_penalty)
          WHERE usr = match_user
                AND usp.org_unit IN ( SELECT * FROM unnest(context_org_list) )
                AND (usp.stop_date IS NULL or usp.stop_date > NOW())
                AND csp.block_list LIKE penalty_type LOOP

        result.fail_part := standing_penalty.name;
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END LOOP;

    -- Fail if the user has too many items with specific circ_modifiers checked out
    FOR out_by_circ_mod IN SELECT * FROM config.circ_matrix_circ_mod_test WHERE matchpoint = circ_test.id LOOP
        SELECT  INTO items_out COUNT(*)
          FROM  action.circulation circ
            JOIN asset.copy cp ON (cp.id = circ.target_copy)
          WHERE circ.usr = match_user
               AND circ.circ_lib IN ( SELECT * FROM unnest(context_org_list) )
            AND circ.checkin_time IS NULL
            AND (circ.stop_fines IN ('MAXFINES','LONGOVERDUE') OR circ.stop_fines IS NULL)
            AND cp.circ_modifier IN (SELECT circ_mod FROM config.circ_matrix_circ_mod_test_map WHERE circ_mod_test = out_by_circ_mod.id);
        IF items_out >= out_by_circ_mod.items_out THEN
            result.fail_part := 'config.circ_matrix_circ_mod_test';
            result.success := FALSE;
            done := TRUE;
            RETURN NEXT result;
        END IF;
    END LOOP;

    -- If we passed everything, return the successful matchpoint id
    IF NOT done THEN
        RETURN NEXT result;
    END IF;

    RETURN;
END;
$func$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION action.item_user_circ_test( INT, BIGINT, INT ) RETURNS SETOF action.matrix_test_result AS $func$
    SELECT * FROM action.item_user_circ_test( $1, $2, $3, FALSE );
$func$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION action.item_user_renew_test( INT, BIGINT, INT ) RETURNS SETOF action.matrix_test_result AS $func$
    SELECT * FROM action.item_user_circ_test( $1, $2, $3, TRUE );
$func$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION actor.calculate_system_penalties( match_user INT, context_org INT ) RETURNS SETOF actor.usr_standing_penalty AS $func$
DECLARE
    user_object         actor.usr%ROWTYPE;
    new_sp_row          actor.usr_standing_penalty%ROWTYPE;
    existing_sp_row     actor.usr_standing_penalty%ROWTYPE;
    collections_fines   permission.grp_penalty_threshold%ROWTYPE;
    max_fines           permission.grp_penalty_threshold%ROWTYPE;
    max_overdue         permission.grp_penalty_threshold%ROWTYPE;
    max_items_out       permission.grp_penalty_threshold%ROWTYPE;
    tmp_grp             INT;
    items_overdue       INT;
    items_out           INT;
    context_org_list    INT[];
    current_fines        NUMERIC(8,2) := 0.0;
    tmp_fines            NUMERIC(8,2);
    tmp_groc            RECORD;
    tmp_circ            RECORD;
    tmp_org             actor.org_unit%ROWTYPE;
    tmp_penalty         config.standing_penalty%ROWTYPE;
    tmp_depth           INTEGER;
BEGIN
    SELECT INTO user_object * FROM actor.usr WHERE id = match_user;

    -- Max fines
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;

    -- Fail if the user has a high fine balance
    LOOP
        tmp_grp := user_object.profile;
        LOOP
            SELECT * INTO max_fines FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = 1 AND org_unit = tmp_org.id;

            IF max_fines.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_fines.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT * INTO tmp_org FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_fines.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
              FROM  actor.usr_standing_penalty
              WHERE usr = match_user
                    AND org_unit = max_fines.org_unit
                    AND (stop_date IS NULL or stop_date > NOW())
                    AND standing_penalty = 1;

        SELECT INTO context_org_list ARRAY_ACCUM(id) FROM actor.org_unit_full_path( max_fines.org_unit );

        SELECT  SUM(f.balance_owed) INTO current_fines
          FROM  money.materialized_billable_xact_summary f
                JOIN (
                    SELECT  r.id
                      FROM  booking.reservation r
                      WHERE r.usr = match_user
                            AND r.pickup_lib IN (SELECT * FROM unnest(context_org_list))
                            AND xact_finish IS NULL
                                UNION ALL
                    SELECT  g.id
                      FROM  money.grocery g
                      WHERE g.usr = match_user
                            AND g.billing_location IN (SELECT * FROM unnest(context_org_list))
                            AND xact_finish IS NULL
                                UNION ALL
                    SELECT  circ.id
                      FROM  action.circulation circ
                      WHERE circ.usr = match_user
                            AND circ.circ_lib IN (SELECT * FROM unnest(context_org_list))
                            AND xact_finish IS NULL ) l USING (id);

        IF current_fines >= max_fines.threshold THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_fines.org_unit;
            new_sp_row.standing_penalty := 1;
            RETURN NEXT new_sp_row;
        END IF;
    END IF;

    -- Start over for max overdue
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;

    -- Fail if the user has too many overdue items
    LOOP
        tmp_grp := user_object.profile;
        LOOP

            SELECT * INTO max_overdue FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = 2 AND org_unit = tmp_org.id;

            IF max_overdue.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_overdue.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT INTO tmp_org * FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_overdue.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
              FROM  actor.usr_standing_penalty
              WHERE usr = match_user
                    AND org_unit = max_overdue.org_unit
                    AND (stop_date IS NULL or stop_date > NOW())
                    AND standing_penalty = 2;

        SELECT  INTO items_overdue COUNT(*)
          FROM  action.circulation circ
                JOIN  actor.org_unit_full_path( max_overdue.org_unit ) fp ON (circ.circ_lib = fp.id)
          WHERE circ.usr = match_user
            AND circ.checkin_time IS NULL
            AND circ.due_date < NOW()
            AND (circ.stop_fines = 'MAXFINES' OR circ.stop_fines IS NULL);

        IF items_overdue >= max_overdue.threshold::INT THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_overdue.org_unit;
            new_sp_row.standing_penalty := 2;
            RETURN NEXT new_sp_row;
        END IF;
    END IF;

    -- Start over for max out
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;

    -- Fail if the user has too many checked out items
    LOOP
        tmp_grp := user_object.profile;
        LOOP
            SELECT * INTO max_items_out FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = 3 AND org_unit = tmp_org.id;

            IF max_items_out.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_items_out.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT INTO tmp_org * FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;


    -- Fail if the user has too many items checked out
    IF max_items_out.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
              FROM  actor.usr_standing_penalty
              WHERE usr = match_user
                    AND org_unit = max_items_out.org_unit
                    AND (stop_date IS NULL or stop_date > NOW())
                    AND standing_penalty = 3;

        SELECT  INTO items_out COUNT(*)
          FROM  action.circulation circ
                JOIN  actor.org_unit_full_path( max_items_out.org_unit ) fp ON (circ.circ_lib = fp.id)
          WHERE circ.usr = match_user
                AND circ.checkin_time IS NULL
                AND (circ.stop_fines IN ('MAXFINES','LONGOVERDUE') OR circ.stop_fines IS NULL);

           IF items_out >= max_items_out.threshold::INT THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_items_out.org_unit;
            new_sp_row.standing_penalty := 3;
            RETURN NEXT new_sp_row;
           END IF;
    END IF;

    -- Start over for collections warning
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;

    -- Fail if the user has a collections-level fine balance
    LOOP
        tmp_grp := user_object.profile;
        LOOP
            SELECT * INTO max_fines FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = 4 AND org_unit = tmp_org.id;

            IF max_fines.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_fines.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT * INTO tmp_org FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_fines.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
              FROM  actor.usr_standing_penalty
              WHERE usr = match_user
                    AND org_unit = max_fines.org_unit
                    AND (stop_date IS NULL or stop_date > NOW())
                    AND standing_penalty = 4;

        SELECT INTO context_org_list ARRAY_ACCUM(id) FROM actor.org_unit_full_path( max_fines.org_unit );

        SELECT  SUM(f.balance_owed) INTO current_fines
          FROM  money.materialized_billable_xact_summary f
                JOIN (
                    SELECT  r.id
                      FROM  booking.reservation r
                      WHERE r.usr = match_user
                            AND r.pickup_lib IN (SELECT * FROM unnest(context_org_list))
                            AND r.xact_finish IS NULL
                                UNION ALL
                    SELECT  g.id
                      FROM  money.grocery g
                      WHERE g.usr = match_user
                            AND g.billing_location IN (SELECT * FROM unnest(context_org_list))
                            AND g.xact_finish IS NULL
                                UNION ALL
                    SELECT  circ.id
                      FROM  action.circulation circ
                      WHERE circ.usr = match_user
                            AND circ.circ_lib IN (SELECT * FROM unnest(context_org_list))
                            AND circ.xact_finish IS NULL ) l USING (id);

        IF current_fines >= max_fines.threshold THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_fines.org_unit;
            new_sp_row.standing_penalty := 4;
            RETURN NEXT new_sp_row;
        END IF;
    END IF;

    -- Start over for in collections
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;

    -- Remove the in-collections penalty if the user has paid down enough
    -- This penalty is different, because this code is not responsible for creating 
    -- new in-collections penalties, only for removing them
    LOOP
        tmp_grp := user_object.profile;
        LOOP
            SELECT * INTO max_fines FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = 30 AND org_unit = tmp_org.id;

            IF max_fines.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_fines.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT * INTO tmp_org FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_fines.threshold IS NOT NULL THEN

        SELECT INTO context_org_list ARRAY_ACCUM(id) FROM actor.org_unit_full_path( max_fines.org_unit );

        -- first, see if the user had paid down to the threshold
        SELECT  SUM(f.balance_owed) INTO current_fines
          FROM  money.materialized_billable_xact_summary f
                JOIN (
                    SELECT  r.id
                      FROM  booking.reservation r
                      WHERE r.usr = match_user
                            AND r.pickup_lib IN (SELECT * FROM unnest(context_org_list))
                            AND r.xact_finish IS NULL
                                UNION ALL
                    SELECT  g.id
                      FROM  money.grocery g
                      WHERE g.usr = match_user
                            AND g.billing_location IN (SELECT * FROM unnest(context_org_list))
                            AND g.xact_finish IS NULL
                                UNION ALL
                    SELECT  circ.id
                      FROM  action.circulation circ
                      WHERE circ.usr = match_user
                            AND circ.circ_lib IN (SELECT * FROM unnest(context_org_list))
                            AND circ.xact_finish IS NULL ) l USING (id);

        IF current_fines IS NULL OR current_fines <= max_fines.threshold THEN
            -- patron has paid down enough

            SELECT INTO tmp_penalty * FROM config.standing_penalty WHERE id = 30;

            IF tmp_penalty.org_depth IS NOT NULL THEN

                -- since this code is not responsible for applying the penalty, it can't 
                -- guarantee the current context org will match the org at which the penalty 
                --- was applied.  search up the org tree until we hit the configured penalty depth
                SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
                SELECT INTO tmp_depth depth FROM actor.org_unit_type WHERE id = tmp_org.ou_type;

                WHILE tmp_depth >= tmp_penalty.org_depth LOOP

                    RETURN QUERY
                        SELECT  *
                          FROM  actor.usr_standing_penalty
                          WHERE usr = match_user
                                AND org_unit = tmp_org.id
                                AND (stop_date IS NULL or stop_date > NOW())
                                AND standing_penalty = 30;

                    IF tmp_org.parent_ou IS NULL THEN
                        EXIT;
                    END IF;

                    SELECT * INTO tmp_org FROM actor.org_unit WHERE id = tmp_org.parent_ou;
                    SELECT INTO tmp_depth depth FROM actor.org_unit_type WHERE id = tmp_org.ou_type;
                END LOOP;

            ELSE

                -- no penalty depth is defined, look for exact matches

                RETURN QUERY
                    SELECT  *
                      FROM  actor.usr_standing_penalty
                      WHERE usr = match_user
                            AND org_unit = max_fines.org_unit
                            AND (stop_date IS NULL or stop_date > NOW())
                            AND standing_penalty = 30;
            END IF;
    
        END IF;

    END IF;

    RETURN;
END;
$func$ LANGUAGE plpgsql;

COMMIT;

