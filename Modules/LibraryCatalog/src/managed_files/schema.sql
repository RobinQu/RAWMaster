CREATE TABLE lc_file_plans(plan_id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, local_binding TEXT NOT NULL, entries TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','published','committed','done','cancelled','detached')));
CREATE TABLE lc_file_steps(plan_id TEXT NOT NULL REFERENCES lc_file_plans, position INTEGER NOT NULL, destination_stamp TEXT, state TEXT NOT NULL CHECK(state IN ('pending','staged','published','done')), PRIMARY KEY(plan_id,position));
CREATE TABLE lc_file_claims(path_key TEXT PRIMARY KEY NOT NULL, plan_id TEXT NOT NULL REFERENCES lc_file_plans);
