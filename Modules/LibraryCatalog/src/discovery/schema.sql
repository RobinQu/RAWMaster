CREATE TABLE lc_discover_state(id INTEGER PRIMARY KEY CHECK(id=1),scene INTEGER NOT NULL,faces INTEGER NOT NULL,human_revision INTEGER NOT NULL,revision INTEGER NOT NULL,paused INTEGER NOT NULL DEFAULT 0);
INSERT INTO lc_discover_state VALUES(1,0,0,0,0,0);
CREATE TABLE lc_discover_jobs(
 job_id TEXT PRIMARY KEY NOT NULL,work_id TEXT NOT NULL,kind TEXT NOT NULL CHECK(kind IN('scene','faces')),
 input_version TEXT NOT NULL,model TEXT NOT NULL,state TEXT NOT NULL,lease TEXT,lease_until INTEGER,attempts INTEGER NOT NULL DEFAULT 0,error TEXT,
 UNIQUE(work_id,kind,input_version,model)
);
CREATE INDEX lc_discover_queue ON lc_discover_jobs(state,kind,job_id);
CREATE TABLE lc_discover_outputs(
 work_id TEXT NOT NULL,kind TEXT NOT NULL,input_version TEXT NOT NULL,model TEXT NOT NULL,proxy_sha TEXT NOT NULL,feature_key TEXT,
 detections INTEGER NOT NULL,PRIMARY KEY(work_id,kind,input_version,model)
);
CREATE TABLE lc_discover_faces(observation_id TEXT PRIMARY KEY NOT NULL,work_id TEXT NOT NULL,input_version TEXT NOT NULL,model TEXT NOT NULL,
 region TEXT NOT NULL,landmarks TEXT NOT NULL,confidence REAL NOT NULL,feature_key TEXT NOT NULL);
CREATE INDEX lc_discover_face_work ON lc_discover_faces(work_id,input_version,model);
CREATE TABLE lc_discover_people(person_id TEXT PRIMARY KEY NOT NULL,name TEXT NOT NULL);
CREATE TABLE lc_discover_anchors(anchor_id TEXT PRIMARY KEY NOT NULL,work_id TEXT NOT NULL,region TEXT NOT NULL);
CREATE INDEX lc_discover_anchor_work ON lc_discover_anchors(work_id);
CREATE TABLE lc_discover_labels(anchor_id TEXT PRIMARY KEY NOT NULL,work_id TEXT NOT NULL,region TEXT NOT NULL,person_id TEXT NOT NULL REFERENCES lc_discover_people);
CREATE INDEX lc_discover_confirmed ON lc_discover_labels(person_id,work_id);
CREATE TABLE lc_discover_rejections(anchor_id TEXT NOT NULL,person_id TEXT NOT NULL REFERENCES lc_discover_people,PRIMARY KEY(anchor_id,person_id));
CREATE TABLE lc_discover_undo(command_id TEXT PRIMARY KEY NOT NULL,before_json TEXT NOT NULL,after_revision INTEGER NOT NULL,undone INTEGER NOT NULL DEFAULT 0);
CREATE TABLE lc_discover_fences(fence_id TEXT PRIMARY KEY NOT NULL,name TEXT NOT NULL,geometry TEXT NOT NULL,revision INTEGER NOT NULL);

CREATE TABLE lc_discover_schedule(kind TEXT PRIMARY KEY NOT NULL,watermark INTEGER NOT NULL,model TEXT NOT NULL,scan_target INTEGER,after_work TEXT);
