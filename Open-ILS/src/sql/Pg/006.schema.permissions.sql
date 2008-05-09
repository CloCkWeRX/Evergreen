DROP SCHEMA permission CASCADE;

BEGIN;
CREATE SCHEMA permission;

CREATE TABLE permission.perm_list (
	id		SERIAL	PRIMARY KEY,
	code		TEXT	NOT NULL UNIQUE,
	description	TEXT
);
CREATE INDEX perm_list_code_idx ON permission.perm_list (code);

CREATE TABLE permission.grp_tree (
	id			SERIAL	PRIMARY KEY,
	name			TEXT	NOT NULL UNIQUE,
	parent			INT	REFERENCES permission.grp_tree (id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
	usergroup		BOOL	NOT NULL DEFAULT TRUE,
	perm_interval		INTERVAL DEFAULT '3 years'::interval NOT NULL,
	description		TEXT,
	application_perm	TEXT
);
CREATE INDEX grp_tree_parent_idx ON permission.grp_tree (parent);

CREATE TABLE permission.grp_perm_map (
	id		SERIAL	PRIMARY KEY,
	grp		INT	NOT NULL REFERENCES permission.grp_tree (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
	perm		INT	NOT NULL REFERENCES permission.perm_list (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
	depth		INT	NOT NULL,
	grantable	BOOL	NOT NULL DEFAULT FALSE,
		CONSTRAINT perm_grp_once UNIQUE (grp,perm)
);

CREATE TABLE permission.usr_perm_map (
	id		SERIAL	PRIMARY KEY,
	usr		INT	NOT NULL REFERENCES actor.usr (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
	perm		INT	NOT NULL REFERENCES permission.perm_list (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
	depth		INT	NOT NULL,
	grantable	BOOL	NOT NULL DEFAULT FALSE,
		CONSTRAINT perm_usr_once UNIQUE (usr,perm)
);

CREATE TABLE permission.usr_grp_map (
	id	SERIAL	PRIMARY KEY,
	usr	INT	NOT NULL REFERENCES actor.usr (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
	grp     INT     NOT NULL REFERENCES permission.grp_tree (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
		CONSTRAINT usr_grp_once UNIQUE (usr,grp)
);

CREATE OR REPLACE FUNCTION permission.grp_ancestors ( INT ) RETURNS SETOF permission.grp_tree AS $$
	SELECT	a.*
	FROM	connectby('permission.grp_tree','parent','id','name',$1,'100','.')
			AS t(keyid text, parent_keyid text, level int, branch text,pos int)
		JOIN permission.grp_tree a ON a.id = t.keyid
	ORDER BY
		CASE WHEN a.parent IS NULL
			THEN 0
			ELSE 1
		END, a.name;
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION permission.usr_perms ( INT ) RETURNS SETOF permission.usr_perm_map AS $$
	SELECT	DISTINCT ON (usr,perm) *
	  FROM	(
			(SELECT * FROM permission.usr_perm_map WHERE usr = $1)
        				UNION ALL
			(SELECT	-p.id, $1 AS usr, p.perm, p.depth, p.grantable
			  FROM	permission.grp_perm_map p
			  WHERE	p.grp IN (
			  	SELECT	(permission.grp_ancestors(
						(SELECT profile FROM actor.usr WHERE id = $1)
					)).id
				)
			)
        				UNION ALL
			(SELECT	-p.id, $1 AS usr, p.perm, p.depth, p.grantable
			  FROM	permission.grp_perm_map p 
			  WHERE	p.grp IN (SELECT (permission.grp_ancestors(m.grp)).id FROM permission.usr_grp_map m WHERE usr = $1))
		) AS x
	  ORDER BY 2, 3, 1 DESC, 5 DESC ;
$$ LANGUAGE SQL STABLE;

CREATE TABLE permission.usr_work_ou_map (
	id	SERIAL	PRIMARY KEY,
	usr	INT	NOT NULL REFERENCES actor.usr (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
	work_ou INT     NOT NULL REFERENCES actor.org_unit (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
		CONSTRAINT usr_work_ou_once UNIQUE (usr,work_ou)
);

CREATE OR REPLACE FUNCTION permission.usr_can_grant_perm ( iuser INT, tperm TEXT, target_ou INT ) RETURNS BOOL AS $$
DECLARE
	r_usr	actor.usr%ROWTYPE;
	r_perm	permission.usr_perm_map%ROWTYPE;
BEGIN

	SELECT * INTO r_usr FROM actor.usr WHERE id = iuser;

	IF r_usr.active = FALSE THEN
		RETURN FALSE;
	END IF;

	IF r_usr.super_user = TRUE THEN
		RETURN TRUE;
	END IF;

	FOR r_perm IN	SELECT	*
			  FROM	permission.usr_perms(iuser) p
				JOIN permission.perm_list l
					ON (l.id = p.perm)
			  WHERE	(l.code = tperm AND p.grantable IS TRUE)
		LOOP

		PERFORM	*
		  FROM	actor.org_unit_descendants(target_ou,r_perm.depth)
		  WHERE	id = r_usr.home_ou;

		IF FOUND THEN
			RETURN TRUE;
		ELSE
			RETURN FALSE;
		END IF;
	END LOOP;

	RETURN FALSE;
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION permission.usr_has_home_perm ( iuser INT, tperm TEXT, target_ou INT ) RETURNS BOOL AS $$
DECLARE
	r_usr	actor.usr%ROWTYPE;
	r_perm	permission.usr_perm_map%ROWTYPE;
BEGIN

	SELECT * INTO r_usr FROM actor.usr WHERE id = iuser;

	IF r_usr.active = FALSE THEN
		RETURN FALSE;
	END IF;

	IF r_usr.super_user = TRUE THEN
		RETURN TRUE;
	END IF;

	FOR r_perm IN	SELECT	*
			  FROM	permission.usr_perms(iuser) p
				JOIN permission.perm_list l
					ON (l.id = p.perm)
			  WHERE	l.code = tperm
			  	OR p.perm = -1 LOOP

		PERFORM	*
		  FROM	actor.org_unit_descendants(target_ou,r_perm.depth)
		  WHERE	id = r_usr.home_ou;

		IF FOUND THEN
			RETURN TRUE;
		ELSE
			RETURN FALSE;
		END IF;
	END LOOP;

	RETURN FALSE;
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION permission.usr_has_work_perm ( iuser INT, tperm TEXT, target_ou INT ) RETURNS BOOL AS $$
DECLARE
	r_woum	permission.usr_work_ou_map%ROWTYPE;
	r_usr	actor.usr%ROWTYPE;
	r_perm	permission.usr_perm_map%ROWTYPE;
BEGIN

	SELECT * INTO r_usr FROM actor.usr WHERE id = iuser;

	IF r_usr.active = FALSE THEN
		RETURN FALSE;
	END IF;

	IF r_usr.super_user = TRUE THEN
		RETURN TRUE;
	END IF;

	FOR r_perm IN	SELECT	*
			  FROM	permission.usr_perms(iuser) p
				JOIN permission.perm_list l
					ON (l.id = p.perm)
			  WHERE	l.code = tperm
			  	OR p.perm = -1
		LOOP

		FOR r_woum IN	SELECT	*
				  FROM	permission.usr_work_ou_map
				  WHERE	usr = iuser
			LOOP

			PERFORM	*
			  FROM	actor.org_unit_descendants(target_ou,r_perm.depth)
			  WHERE	id = r_woum.work_ou;

			IF FOUND THEN
				RETURN TRUE;
			END IF;

		END LOOP;

	END LOOP;

	RETURN FALSE;
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION permission.usr_has_perm ( INT, TEXT, INT ) RETURNS BOOL AS $$
	SELECT	CASE
			WHEN permission.usr_has_home_perm( $1, $2, $3 ) THEN TRUE
			WHEN permission.usr_has_work_perm( $1, $2, $3 ) THEN TRUE
			ELSE FALSE
		END;
$$ LANGUAGE SQL;

COMMIT;

